// Package sshrelay forwards public TCP ports to port 22 of running sandbox
// VMs. It is a plain byte relay: SSH auth happens in the guest sshd. Each
// sandbox gets at most one listener, and its only destination is
// <sandbox IP>:22, so clients cannot pick where the relay connects.
package sshrelay

import (
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

var ErrExhausted = errors.New("ssh relay: no free port in range")

// countAfter: a relay connection counts as an SSH session only once it has
// outlived the guest sshd's LoginGraceTime (20s). sshd drops connections that
// have not authenticated by then, so a raw TCP connection cannot keep a VM
// counted as busy.
var countAfter = 30 * time.Second

const (
	maxSessionsPerSandbox = 8
	dialTimeout           = 5 * time.Second
)

type Relay struct {
	host       string
	start, end int
	targetPort string // always "22" outside tests
	mu         sync.Mutex
	byID       map[string]*listener
}

func New(host string, start, end int) *Relay {
	return &Relay{host: host, start: start, end: end, targetPort: "22", byID: map[string]*listener{}}
}

// Host returns the public host that clients connect to.
func (r *Relay) Host() string { return r.host }

// Ensure opens or reuses the listener for sandbox id, forwarding to ip:22.
// It tries preferred first, so a restarted manager keeps existing ports.
func (r *Relay) Ensure(id, ip string, preferred int) (int, error) {
	if r == nil {
		return 0, errors.New("ssh relay disabled")
	}
	parsed := net.ParseIP(ip)
	if parsed == nil || parsed.To4() == nil || !(parsed.IsPrivate() || parsed.IsLoopback()) {
		return 0, fmt.Errorf("ssh relay: invalid sandbox IP %q", ip)
	}
	target := net.JoinHostPort(parsed.String(), r.targetPort)

	r.mu.Lock()
	defer r.mu.Unlock()
	if l := r.byID[id]; l != nil {
		if l.target == target {
			return l.port, nil
		}
		delete(r.byID, id)
		l.close()
	}
	used := map[int]bool{}
	for _, l := range r.byID {
		used[l.port] = true
	}
	candidates := make([]int, 0, r.end-r.start+2)
	if preferred >= r.start && preferred <= r.end {
		candidates = append(candidates, preferred)
	}
	for p := r.start; p <= r.end; p++ {
		candidates = append(candidates, p)
	}
	for _, p := range candidates {
		if used[p] {
			continue
		}
		ln, err := net.Listen("tcp", fmt.Sprintf(":%d", p))
		if err != nil {
			continue // held by another process
		}
		l := &listener{port: p, target: target, ln: ln, sessions: map[*session]struct{}{}}
		r.byID[id] = l
		go l.serve()
		return p, nil
	}
	return 0, ErrExhausted
}

// Close stops the listener for id and closes its active connections.
func (r *Relay) Close(id string) {
	if r == nil {
		return
	}
	r.mu.Lock()
	l := r.byID[id]
	delete(r.byID, id)
	r.mu.Unlock()
	if l != nil {
		l.close()
	}
}

// Retain closes every listener whose id is missing from keep or whose target
// IP changed. keep maps a sandbox id to its current IP.
func (r *Relay) Retain(keep map[string]string) {
	if r == nil {
		return
	}
	r.mu.Lock()
	var stale []*listener
	for id, l := range r.byID {
		if ip, ok := keep[id]; !ok || l.target != net.JoinHostPort(ip, r.targetPort) {
			stale = append(stale, l)
			delete(r.byID, id)
		}
	}
	r.mu.Unlock()
	for _, l := range stale {
		l.close()
	}
}

// Connections returns the number of live SSH sessions for id (see countAfter).
func (r *Relay) Connections(id string) int {
	if r == nil {
		return 0
	}
	r.mu.Lock()
	l := r.byID[id]
	r.mu.Unlock()
	if l == nil {
		return 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	n := 0
	for s := range l.sessions {
		if s.upstream != nil && time.Since(s.start) >= countAfter {
			n++
		}
	}
	return n
}

type listener struct {
	port     int
	target   string
	ln       net.Listener
	mu       sync.Mutex
	closed   bool
	sessions map[*session]struct{}
}

type session struct {
	client, upstream net.Conn
	start            time.Time
}

func (l *listener) serve() {
	for {
		c, err := l.ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(100 * time.Millisecond) // transient, e.g. EMFILE
			continue
		}
		s := &session{client: c, start: time.Now()}
		l.mu.Lock()
		ok := !l.closed && len(l.sessions) < maxSessionsPerSandbox
		if ok {
			l.sessions[s] = struct{}{}
		}
		l.mu.Unlock()
		if !ok {
			c.Close()
			continue
		}
		go l.pipe(s)
	}
}

func (l *listener) pipe(s *session) {
	defer l.drop(s)
	up, err := net.DialTimeout("tcp", l.target, dialTimeout)
	if err != nil {
		return
	}
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		up.Close()
		return
	}
	s.upstream = up
	l.mu.Unlock()
	done := make(chan struct{}, 2)
	go func() { io.Copy(up, s.client); done <- struct{}{} }()
	go func() { io.Copy(s.client, up); done <- struct{}{} }()
	<-done // either side ended: drop closes both
}

func (l *listener) drop(s *session) {
	l.mu.Lock()
	delete(l.sessions, s)
	up := s.upstream
	l.mu.Unlock()
	s.client.Close()
	if up != nil {
		up.Close()
	}
}

func (l *listener) close() {
	l.ln.Close()
	l.mu.Lock()
	l.closed = true
	for s := range l.sessions {
		s.client.Close()
		if s.upstream != nil {
			s.upstream.Close()
		}
	}
	l.mu.Unlock()
}
