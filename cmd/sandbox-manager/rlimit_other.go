//go:build !linux

package main

// raiseFileLimit is a no-op off Linux; the manager only runs on Linux (it drives
// containerd/Kata/Firecracker), this keeps `go build ./...` working elsewhere.
func raiseFileLimit() {}
