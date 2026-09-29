package config

import "testing"

func TestValidateSSHAuthURL(t *testing.T) {
	const p = "/api/cloud-ssh/authorized-key"
	cases := []struct {
		url, env string
		ok       bool
	}{
		{"https://api.todofor.ai" + p, "production", true},
		{"https://api.todofor.ai" + p, "", true},
		{"http://localhost:4000" + p, "development", true},
		{"http://10.88.0.1:4000" + p, "development", true},
		{"http://127.0.0.1:4000" + p, "test", true},
		{"http://10.88.0.1:4000" + p, "", false},            // env unset is not dev
		{"http://10.88.0.1:4000" + p, "production", false},  // never http in prod
		{"http://api.todofor.ai" + p, "development", false}, // public host over http
		{"https://api.todofor.ai/api/other", "production", false},
		{"https://api.todofor.ai" + p + "?x=1", "production", false},
		{"https://api.todofor.ai" + p + "?", "production", false},
		{"https://api.todofor.ai" + p + "#f", "production", false},
		{"https://u:p@api.todofor.ai" + p, "production", false},
		{"ftp://api.todofor.ai" + p, "development", false},
		{p, "development", false},
	}
	for _, c := range cases {
		if err := validateSSHAuthURL(c.url, c.env); (err == nil) != c.ok {
			t.Errorf("validateSSHAuthURL(%q, %q) = %v, want ok=%v", c.url, c.env, err, c.ok)
		}
	}
}

func TestLoadSSH(t *testing.T) {
	set := func(host, start, end string) {
		t.Setenv("SSH_PUBLIC_HOST", host)
		t.Setenv("SSH_PORT_START", start)
		t.Setenv("SSH_PORT_END", end)
		t.Setenv("SSH_AUTH_URL", "")
		t.Setenv("NODE_ENV", "production")
	}
	c := &Config{BackendURL: "https://api.todofor.ai/"}
	set("", "", "")
	if err := c.loadSSH(); err != nil || c.SSHEnabled() {
		t.Fatalf("unset must disable: %v", err)
	}
	for _, bad := range [][3]string{
		{"ssh.todofor.ai", "", ""}, {"", "2200", "2300"}, {"ssh.todofor.ai", "2300", "2200"},
		{"ssh.todofor.ai", "2200", "70000"}, {"bad host", "2200", "2300"},
	} {
		set(bad[0], bad[1], bad[2])
		if err := (&Config{BackendURL: "https://api.todofor.ai"}).loadSSH(); err == nil {
			t.Errorf("accepted %v", bad)
		}
	}
	set("ssh.todofor.ai", "2200", "2300")
	c = &Config{BackendURL: "https://api.todofor.ai/"}
	if err := c.loadSSH(); err != nil || !c.SSHEnabled() {
		t.Fatal(err)
	}
	if c.SSHAuthURL != "https://api.todofor.ai/api/cloud-ssh/authorized-key" || c.SSHPortStart != 2200 || c.SSHPortEnd != 2300 {
		t.Fatalf("derived %+v", c)
	}
}
