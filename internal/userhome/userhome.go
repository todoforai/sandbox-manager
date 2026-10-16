package userhome

import (
	"bytes"
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

// Delete permanently removes a user's persistent home image and directory.
func (s *Store) Delete(userID string) error {
	dir, err := s.dir(userID)
	if err != nil {
		return err
	}
	return os.RemoveAll(dir)
}

// growDisk extends a sparse ext4 image and its filesystem to size bytes. The
// image is not mounted here (one sandbox per user, called before the VM
// attaches), so an offline resize2fs is safe; it requires a clean fs, hence
// the preen fsck first.
func growDisk(path string, size int64) error {
	if err := os.Truncate(path, size); err != nil {
		return fmt.Errorf("grow %s: %w", path, err)
	}
	if out, err := exec.Command("e2fsck", "-fp", path).CombinedOutput(); err != nil {
		// exit 1 = errors corrected; only ≥2 is a real failure
		if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() > 1 {
			return fmt.Errorf("e2fsck %s: %v: %s", path, err, out)
		}
	}
	if out, err := exec.Command("resize2fs", path).CombinedOutput(); err != nil {
		return fmt.Errorf("resize2fs %s: %v: %s", path, err, out)
	}
	return nil
}

var validID = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

func (s *Store) dir(userID string) (string, error) {
	if userID == "" || userID == "." || userID == ".." || len(userID) > 128 || !validID.MatchString(userID) {
		return "", fmt.Errorf("invalid user_id %q", userID)
	}
	return filepath.Join(s.root, userID), nil
}

// shrinkHeadroom: a shrink must leave the fs at least this much bigger than
// its data, so the guest isn't left with a full home (fatal, see EnsureDisk).
const shrinkHeadroom = 1.2

// shrinkDisk shrinks an unmounted ext4 image to size bytes only when its data
// fits with headroom; otherwise it leaves the image untouched and returns false.
func shrinkDisk(path string, size int64) (bool, error) {
	if out, err := exec.Command("e2fsck", "-fp", path).CombinedOutput(); err != nil {
		if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() > 1 {
			return false, fmt.Errorf("e2fsck %s: %v: %s", path, err, out)
		}
	}
	out, err := exec.Command("resize2fs", "-P", path).CombinedOutput()
	if err != nil {
		return false, fmt.Errorf("resize2fs -P %s: %v: %s", path, err, out)
	}
	minBlocks, err := lastNumber(out)
	if err != nil {
		return false, fmt.Errorf("parse resize2fs -P %q: %v", out, err)
	}
	hdr, err := exec.Command("dumpe2fs", "-h", path).Output()
	if err != nil {
		return false, fmt.Errorf("dumpe2fs %s: %v", path, err)
	}
	blockSize, err := lastNumber(blockSizeLine.Find(hdr))
	if err != nil {
		return false, fmt.Errorf("parse block size: %v", err)
	}
	if float64(minBlocks*blockSize)*shrinkHeadroom > float64(size) {
		return false, nil
	}
	if out, err := exec.Command("resize2fs", path, fmt.Sprintf("%dK", size/1024)).CombinedOutput(); err != nil {
		return false, fmt.Errorf("resize2fs %s: %v: %s", path, err, out)
	}
	return true, os.Truncate(path, size)
}

var blockSizeLine = regexp.MustCompile(`(?m)^Block size:\s*\d+`)

func lastNumber(b []byte) (int64, error) {
	var n int64
	_, err := fmt.Sscanf(string(b[bytes.LastIndexAny(bytes.TrimSpace(b), ": ")+1:]), "%d", &n)
	return n, err
}

// DiskMiB is the current size of the user's home image (0 if none yet).
func (s *Store) DiskMiB(userID string) uint64 {
	dir, err := s.dir(userID)
	if err != nil {
		return 0
	}
	st, err := os.Stat(filepath.Join(dir, "home.img"))
	if err != nil {
		return 0
	}
	return uint64(st.Size() / (1024 * 1024))
}

// ShrinkDisk tries to bring an existing image down to sizeMiB. A no-op when
// it is already that small or its files don't fit — never loses data.
func (s *Store) ShrinkDisk(userID string, sizeMiB uint64) error {
	if s.DiskMiB(userID) <= sizeMiB {
		return nil
	}
	dir, _ := s.dir(userID)
	_, err := shrinkDisk(filepath.Join(dir, "home.img"), int64(sizeMiB)*1024*1024)
	return err
}

// EnsureDisk returns the path to the user's home.img, creating + formatting it
// (sparse, size_mib ceiling) on first call. Idempotent: an existing image is
// never reformatted (would destroy user data), but it IS grown to sizeMiB when
// smaller — e.g. a disk created on a lower tier. A full home is fatal: the
// entrypoint can't write credentials.json, enrollment fails, the bridge loops
// on 4401 and the VM dies silently. Never shrinks.
func (s *Store) EnsureDisk(userID string, sizeMiB uint64) (string, error) {
	dir, err := s.dir(userID)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(dir, "home.img")
	if st, err := os.Stat(path); err == nil {
		want := int64(sizeMiB) * 1024 * 1024
		if st.Size() < want {
			if err := growDisk(path, want); err != nil {
				return "", err
			}
		}
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
