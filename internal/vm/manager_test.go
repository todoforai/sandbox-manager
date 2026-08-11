package vm

import "testing"

func TestMachineResourcesForSize(t *testing.T) {
	cases := map[string]machineResources{
		"small":   {memoryMiB: 256, vCPUs: 1},
		"medium":  {memoryMiB: 512, vCPUs: 1},
		"large":   {memoryMiB: 1024, vCPUs: 2},
		"xlarge":  {memoryMiB: 2048, vCPUs: 4},
		"":        {memoryMiB: 512, vCPUs: 1},
		"unknown": {memoryMiB: 512, vCPUs: 1},
	}
	for size, want := range cases {
		if got := machineResourcesForSize(size); got != want {
			t.Errorf("machineResourcesForSize(%q) = %+v, want %+v", size, got, want)
		}
	}
}

func TestMachineResourceAnnotations(t *testing.T) {
	got := machineResourceAnnotations("large")
	want := map[string]string{
		kataDefaultVCPUsAnnotation:    "2",
		kataDefaultMaxVCPUsAnnotation: "2",
		kataDefaultMemoryAnnotation:   "1024",
	}
	for key, value := range want {
		if got[key] != value {
			t.Errorf("annotation %q = %q, want %q", key, got[key], value)
		}
	}
}
