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
	mux.HandleFunc("POST /sandbox/{id}/attach-device", s.auth(s.attachDevice))
	mux.HandleFunc("GET /stats", s.auth(s.stats))
	mux.HandleFunc("GET /templates", s.auth(s.templates))

	// Admin UI surface. Same handlers, but the panel talks /admin/api/* and
	// expects an admin bearer token. List/Get/Delete already widen to all
	// users when the identity is admin (see service.go), so no new logic —
	// just route aliases gated on the admin role.
	mux.HandleFunc("GET /admin/api/sandbox", s.admin(s.list))
	mux.HandleFunc("GET /admin/api/sandbox/{id}", s.admin(s.get))
	mux.HandleFunc("DELETE /admin/api/sandbox/{id}", s.admin(s.delete))
	mux.HandleFunc("GET /admin/api/stats", s.admin(s.stats))
	return mux
}

type authedHandler func(http.ResponseWriter, *http.Request, store.Identity)

// auth extracts the bearer token, resolves identity via Redis, and injects it.
func (s *Server) auth(h authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		tok, ok := strings.CutPrefix(auth, "Bearer ")
		if !ok || tok == "" {
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

// admin is auth + an admin-role gate, for the /admin/api/* panel routes.
func (s *Server) admin(h authedHandler) http.HandlerFunc {
	return s.auth(func(w http.ResponseWriter, r *http.Request, id store.Identity) {
		if !id.IsAdmin() {
			httpErr(w, http.StatusForbidden, "admin role required")
			return
		}
		h(w, r, id)
	})
}

// templates lists the sandbox templates a user can boot. There's no dynamic
// registry yet, so this is the static set the rootfs supports.
func (s *Server) templates(w http.ResponseWriter, r *http.Request, _ store.Identity) {
	writeJSON(w, http.StatusOK, []map[string]string{
		{"id": "ubuntu-base", "name": "Ubuntu base", "description": "Default Ubuntu userland with the tfa-* CLI toolset."},
	})
}

func (s *Server) create(w http.ResponseWriter, r *http.Request, id store.Identity) {
	var req struct {
		UserID   string `json:"user_id"`
		Template string `json:"template"`
		Size     string `json:"size"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	// Admin (the backend's admin API key) provisions on a user's behalf: the
	// body's user_id is the real owner. Without this the sandbox would be
	// reserved/created under the admin identity, not the target user.
	if id.IsAdmin() && req.UserID != "" {
		id.UserID = req.UserID
	}
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
	// Admin can scope to one user via ?user_id= (the backend's idempotent
	// list-then-create) without giving up admin identity.
	if id.IsAdmin() {
		id.ScopeUserID = r.URL.Query().Get("user_id")
	}
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if len(req.Argv) == 0 {
		httpErr(w, http.StatusBadRequest, "argv is required")
		return
	}
	out, err := s.svc.Exec(r.Context(), id, r.PathValue("id"), req.Argv)
	if err != nil {
		writeServiceErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"output": string(out)})
}

func (s *Server) attachDevice(w http.ResponseWriter, r *http.Request, id store.Identity) {
	var req struct {
		DeviceID string `json:"device_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.DeviceID == "" {
		httpErr(w, http.StatusBadRequest, "device_id is required")
		return
	}
	if err := s.svc.AttachDevice(r.Context(), id, r.PathValue("id"), req.DeviceID); err != nil {
		writeServiceErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
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
