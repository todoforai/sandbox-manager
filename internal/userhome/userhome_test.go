package userhome

import (
	"path/filepath"
	"testing"
)

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
