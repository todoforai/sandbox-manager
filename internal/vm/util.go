package vm

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
)

// outputBuffer is a tiny thread-safe io.Writer for capturing exec output.
type outputBuffer struct {
	mu  sync.Mutex
	buf []byte
}

func (b *outputBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.buf = append(b.buf, p...)
	return len(p), nil
}

func (b *outputBuffer) Bytes() []byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]byte, len(b.buf))
	copy(out, b.buf)
	return out
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}
