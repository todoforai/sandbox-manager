package sshrelay

import (
	"io"
	"net"
	"strconv"
	"testing"
	"time"
)

// echoServer stands in for the guest sshd.
func echoServer(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	return port
}

func freeRange(t *testing.T, n int) (int, int) {
	t.Helper()
	for base := 42000; base < 60000; base += 50 {
		ok := true
		for p := base; p < base+n; p++ {
			ln, err := net.Listen("tcp", ":"+strconv.Itoa(p))
			if err != nil {
				ok = false
				break
			}
			ln.Close()
		}
		if ok {
			return base, base + n - 1
		}
	}
	t.Fatal("no free port range")
	return 0, 0
}

func newTestRelay(t *testing.T, n int) *Relay {
	start, end := freeRange(t, n)
	r := New("ssh.example.com", start, end)
	r.targetPort = echoServer(t)
	return r
}

func dial(t *testing.T, port int) net.Conn {
	t.Helper()
	c, err := net.Dial("tcp", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func roundTrip(t *testing.T, c net.Conn) {
	t.Helper()
	c.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := c.Write([]byte("hi")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 2)
	if _, err := io.ReadFull(c, buf); err != nil || string(buf) != "hi" {
		t.Fatalf("relay echo: %q %v", buf, err)
	}
}

func waitClosed(t *testing.T, c net.Conn) {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("connection still open")
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatal("connection not closed")
	}
}

func TestAllocationUniqueStableAndExhaustion(t *testing.T) {
	r := newTestRelay(t, 2)
	defer r.Retain(nil)
	a, err := r.Ensure("a", "127.0.0.1", 0)
	if err != nil {
		t.Fatal(err)
	}
	if again, _ := r.Ensure("a", "127.0.0.1", 0); again != a {
		t.Fatalf("Ensure not idempotent: %d vs %d", again, a)
	}
	b, err := r.Ensure("b", "127.0.0.1", a) // preferred port taken by a
	if err != nil || b == a {
		t.Fatalf("b = %d (%v), a = %d", b, err, a)
	}
	if _, err := r.Ensure("c", "127.0.0.1", 0); err != ErrExhausted {
		t.Fatalf("want ErrExhausted, got %v", err)
	}
	r.Close("a")
	if c, err := r.Ensure("c", "127.0.0.1", 0); err != nil || c != a {
		t.Fatalf("freed port not reused: %d %v", c, err)
	}
}

func TestPreferredPortKept(t *testing.T) {
	r := newTestRelay(t, 3)
	defer r.Retain(nil)
	if p, err := r.Ensure("a", "127.0.0.1", r.end); err != nil || p != r.end {
		t.Fatalf("preferred port: %d %v", p, err)
	}
	if p, _ := r.Ensure("b", "127.0.0.1", 99); p != r.start {
		t.Fatalf("out-of-range preference must be ignored, got %d", p)
	}
}

func TestRejectsNonIPv4Target(t *testing.T) {
	r := newTestRelay(t, 1)
	for _, ip := range []string{"", "example.com", "::1", "10.0.0.1:22", "8.8.8.8"} {
		if _, err := r.Ensure("a", ip, 0); err == nil {
			t.Errorf("Ensure accepted target %q", ip)
		}
	}
	var nilRelay *Relay
	if _, err := nilRelay.Ensure("a", "127.0.0.1", 0); err == nil {
		t.Error("nil relay must refuse")
	}
	if nilRelay.Connections("a") != 0 {
		t.Error("nil relay count")
	}
	nilRelay.Close("a")
	nilRelay.Retain(nil)
}

func TestCloseDropsActiveConnections(t *testing.T) {
	r := newTestRelay(t, 1)
	port, _ := r.Ensure("a", "127.0.0.1", 0)
	c := dial(t, port)
	roundTrip(t, c)
	r.Close("a")
	waitClosed(t, c)
	if _, err := net.Dial("tcp", "127.0.0.1:"+strconv.Itoa(port)); err == nil {
		t.Fatal("listener still accepting after Close")
	}
}

func TestRetainClosesStaleAndMovedTargets(t *testing.T) {
	r := newTestRelay(t, 3)
	defer r.Retain(nil)
	pa, _ := r.Ensure("a", "127.0.0.1", 0)
	pb, _ := r.Ensure("b", "127.0.0.1", 0)
	r.Ensure("c", "127.0.0.1", 0)
	ca, cb := dial(t, pa), dial(t, pb)
	roundTrip(t, ca)
	roundTrip(t, cb)
	r.Retain(map[string]string{"a": "127.0.0.1", "b": "127.0.0.2"}) // c gone, b moved
	roundTrip(t, ca)
	waitClosed(t, cb)
	if r.Connections("c") != 0 {
		t.Fatal("c should be gone")
	}
}

func TestConnectionsCountOnlyAfterGrace(t *testing.T) {
	old := countAfter
	countAfter = 200 * time.Millisecond
	defer func() { countAfter = old }()
	r := newTestRelay(t, 1)
	defer r.Retain(nil)
	port, _ := r.Ensure("a", "127.0.0.1", 0)
	c := dial(t, port)
	roundTrip(t, c)
	if n := r.Connections("a"); n != 0 {
		t.Fatalf("counted before grace: %d", n)
	}
	time.Sleep(250 * time.Millisecond)
	if n := r.Connections("a"); n != 1 {
		t.Fatalf("want 1 after grace, got %d", n)
	}
	c.Close()
	deadline := time.Now().Add(2 * time.Second)
	for r.Connections("a") != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if n := r.Connections("a"); n != 0 {
		t.Fatalf("closed conn still counted: %d", n)
	}
}

func TestPerSandboxSessionCap(t *testing.T) {
	r := newTestRelay(t, 1)
	defer r.Retain(nil)
	port, _ := r.Ensure("a", "127.0.0.1", 0)
	for i := 0; i < maxSessionsPerSandbox; i++ {
		roundTrip(t, dial(t, port))
	}
	waitClosed(t, dial(t, port))
}
