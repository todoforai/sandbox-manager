package userhome

import (
	"bytes"
	"crypto/rand"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestDeleteRemovesUserHome(t *testing.T) {
	root := t.TempDir()
	s := New(root)
	dir, err := s.dir("user123")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "home.img"), []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.Delete("user123"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("user home still exists after delete: %v", err)
	}
}

func TestDirValidation(t *testing.T) {
	s := New("/data/user-homes")

	for _, bad := range []string{
		"", ".", "..", "../etc", "a/b", "a\\b", "user id", "u\x00id",
		string(make([]byte, 129)), // > 128
	} {
		if _, err := s.dir(bad); err == nil {
			t.Errorf("dir(%q): want error, got nil", bad)
		}
	}

	for _, good := range []string{"user123", "a-b_c.d", "ABC", "0"} {
		got, err := s.dir(good)
		if err != nil {
			t.Errorf("dir(%q): unexpected error %v", good, err)
			continue
		}
		if want := filepath.Join("/data/user-homes", good); got != want {
			t.Errorf("dir(%q) = %q, want %q", good, got, want)
		}
	}
}

func TestShrinkDisk(t *testing.T) {
	if _, err := exec.LookPath("resize2fs"); err != nil {
		t.Skip("e2fsprogs not installed")
	}
	s := New(t.TempDir())
	if _, err := s.EnsureDisk("u", 200); err != nil {
		t.Fatal(err)
	}
	// Data that fits with headroom: shrunk, files kept.
	img := filepath.Join(s.root, "u", "home.img")
	blob := filepath.Join(t.TempDir(), "blob")
	if err := os.WriteFile(blob, randomBytes(20<<20), 0o600); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("debugfs", "-w", "-R", "write "+blob+" blob", img).CombinedOutput(); err != nil {
		t.Fatalf("debugfs: %v %s", err, out)
	}
	if err := s.ShrinkDisk("u", 64); err != nil {
		t.Fatal(err)
	}
	if got := s.DiskMiB("u"); got != 64 {
		t.Fatalf("disk not shrunk: %d MiB", got)
	}
	if out, _ := exec.Command("debugfs", "-R", "stat blob", img).CombinedOutput(); !bytes.Contains(out, []byte("Size: 20971520")) {
		t.Fatalf("file lost in shrink: %s", out)
	}
	// Data that doesn't fit with headroom: the disk is left alone.
	if err := s.ShrinkDisk("u", 24); err != nil {
		t.Fatal(err)
	}
	if got := s.DiskMiB("u"); got != 64 {
		t.Fatalf("full disk was shrunk: %d MiB", got)
	}
	if out, err := exec.Command("e2fsck", "-fn", img).CombinedOutput(); err != nil {
		t.Fatalf("fs damaged: %v %s", err, out)
	}
}

func randomBytes(n int) []byte {
	b := make([]byte, n)
	rand.Read(b)
	return b
}
