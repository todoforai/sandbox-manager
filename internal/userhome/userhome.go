package userhome

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
)

// Store manages each user's persistent $HOME disk image. Each user gets one
// home.img (ext4) at <root>/<userId>/home.img, attached to their sandbox VM as
// an extra drive.
//
// Simpler than the old Rust version: NO flock / eviction machinery. The service
// layer guarantees one sandbox per user, so there is never a second mounter.
type Store struct {
	root string
}

func New(root string) *Store { return &Store{root: root} }

var validID = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

func (s *Store) dir(userID string) (string, error) {
	if userID == "" || userID == "." || userID == ".." || len(userID) > 128 || !validID.MatchString(userID) {
		return "", fmt.Errorf("invalid user_id %q", userID)
	}
	return filepath.Join(s.root, userID), nil
}

// EnsureDisk returns the path to the user's home.img, creating + formatting it
// (sparse, size_mib ceiling) on first call. Idempotent: an existing image is
// returned untouched — never reformatted (would destroy user data).
func (s *Store) EnsureDisk(userID string, sizeMiB uint64) (string, error) {
	dir, err := s.dir(userID)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(dir, "home.img")
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}
	f, err := os.Create(path)
	if err != nil {
		return "", err
	}
	if err := f.Truncate(int64(sizeMiB) * 1024 * 1024); err != nil {
		f.Close()
		return "", err
	}
	f.Close()
	// lazy init keeps mkfs near-instant on a large sparse file.
	cmd := exec.Command("mkfs.ext4", "-F", "-E", "lazy_itable_init=1,lazy_journal_init=1", path)
	if out, err := cmd.CombinedOutput(); err != nil {
		os.Remove(path)
		return "", fmt.Errorf("mkfs.ext4: %v: %s", err, out)
	}
	return path, nil
}
