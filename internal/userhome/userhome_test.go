package userhome

import (
	"os"
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
