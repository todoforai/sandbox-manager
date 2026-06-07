package service

import (
	"crypto/rand"
	"encoding/hex"
)

// VM tier pricing (USD/min), ported from the old vm/size.rs. Lite is gone.
func costPerMinute(size string) float64 {
	switch size {
	case "small":
		return 0.0025
	case "medium":
		return 0.005
	case "large":
		return 0.01
	case "xlarge":
		return 0.02
	default:
		return 0.005
	}
}

func newID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}
