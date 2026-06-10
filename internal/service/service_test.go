package service

import "testing"

func TestCostPerMinute(t *testing.T) {
	cases := map[string]float64{
		"small": 0.0025, "medium": 0.005, "large": 0.01, "xlarge": 0.02,
		"": 0.005, "bogus": 0.005, // unknown tiers fall back to medium
	}
	for size, want := range cases {
		if got := costPerMinute(size); got != want {
			t.Errorf("costPerMinute(%q) = %v, want %v", size, got, want)
		}
	}
}

func TestDiskSizeMiBForTier(t *testing.T) {
	cases := map[string]uint64{
		"small": 500, "medium": 2048, "large": 8192, "xlarge": 20480,
		"": 2048, "bogus": 2048,
	}
	for size, want := range cases {
		if got := diskSizeMiBForTier(size); got != want {
			t.Errorf("diskSizeMiBForTier(%q) = %v, want %v", size, got, want)
		}
	}
}

func TestDiskUsagePercent(t *testing.T) {
	got, err := diskUsagePercent(t.TempDir())
	if err != nil {
		t.Fatalf("diskUsagePercent: %v", err)
	}
	if got < 0 || got > 100 {
		t.Errorf("diskUsagePercent = %d, want 0..100", got)
	}
	if _, err := diskUsagePercent("/nonexistent-path-xyz"); err == nil {
		t.Error("diskUsagePercent on missing path: want error, got nil")
	}
}

func TestNewID(t *testing.T) {
	a, b := newID(), newID()
	if len(a) != 32 {
		t.Errorf("newID length = %d, want 32", len(a))
	}
	if a == b {
		t.Error("newID returned duplicates")
	}
}
