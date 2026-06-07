package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/todoforai/sandbox-manager/internal/service"
	"github.com/todoforai/sandbox-manager/internal/store"
)

// Server is the HTTP API. The whole public surface the old service had, minus
// the dropped features (pause/resume/balloon/restart-bridge/recovery-cert/
// noise transport). Plain HTTP+TLS; the CLI no longer needs the Noise adapter.
type Server struct {
	store *store.Store
	svc   *service.Service
}

func NewServer(st *store.Store, svc *service.Service) http.Handler {
	s := &Server{store: st, svc: svc}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("GET /sandbox", s.auth(s.list))
	mux.HandleFunc("POST /sandbox", s.auth(s.create))
	mux.HandleFunc("GET /sandbox/{id}", s.auth(s.get))
	mux.HandleFunc("DELETE /sandbox/{id}", s.auth(s.delete))
	mux.HandleFunc("POST /sandbox/{id}/exec", s.auth(s.exec))
	mux.HandleFunc("GET /stats", s.auth(s.stats))
	return mux
}

type authedHandler func(http.ResponseWriter, *http.Request, store.Identity)

// auth extracts the bearer token, resolves identity via Redis, and injects it.
func (s *Server) auth(h authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if tok == "" {
			httpErr(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		id, err := s.store.ResolveIdentity(r.Context(), tok)
		if err != nil || id == nil {
			httpErr(w, http.StatusUnauthorized, "invalid token")
			return
		}
		h(w, r, *id)
	}
}

func (s *Server) create(w http.ResponseWriter, r *http.Request, id store.Identity) {
	var req struct {
		Template string `json:"template"`
		Size     string `json:"size"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	sb, err := s.svc.Create(r.Context(), id, req.Template, req.Size)
	if err != nil {
		writeServiceErr(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, sb)
}

func (s *Server) get(w http.ResponseWriter, r *http.Request, id store.Identity) {
	sb, err := s.svc.Get(r.Context(), id, r.PathValue("id"))
	if err != nil {
		writeServiceErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sb)
}

func (s *Server) list(w http.ResponseWriter, r *http.Request, id store.Identity) {
	list, err := s.svc.List(r.Context(), id)
	if err != nil {
		httpErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, list)
}

func (s *Server) delete(w http.ResponseWriter, r *http.Request, id store.Identity) {
	if err := s.svc.Delete(r.Context(), id, r.PathValue("id")); err != nil {
		writeServiceErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) exec(w http.ResponseWriter, r *http.Request, id store.Identity) {
	var req struct {
		Argv []string `json:"argv"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	out, err := s.svc.Exec(r.Context(), id, r.PathValue("id"), req.Argv)
	if err != nil {
		writeServiceErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"output": string(out)})
}

func (s *Server) stats(w http.ResponseWriter, r *http.Request, _ store.Identity) {
	st, err := s.svc.Stats(r.Context())
	if err != nil {
		httpErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, st)
}

// ── helpers ──────────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func httpErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func writeServiceErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, service.ErrNotFound):
		httpErr(w, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrForbidden):
		httpErr(w, http.StatusForbidden, err.Error())
	case errors.Is(err, service.ErrQuota), errors.Is(err, service.ErrAnonymous):
		httpErr(w, http.StatusConflict, err.Error())
	default:
		httpErr(w, http.StatusInternalServerError, err.Error())
	}
}
