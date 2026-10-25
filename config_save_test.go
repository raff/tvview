package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// cfgDir makes a config directory with a wireguard/ folder, under a temp HOME
// so ~ paths and the iCloud lookup stay inside the test.
func cfgDir(t *testing.T) (dir string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir = filepath.Join(home, "cfg")
	if err := os.MkdirAll(filepath.Join(dir, "wireguard"), 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}

func touch(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("[Interface]\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func load(t *testing.T, path, text string) *Config {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestPendingTunnelLoads(t *testing.T) {
	dir := cfgDir(t)
	path := filepath.Join(dir, "channels.yaml")
	// The unquoted form is a YAML comment, so IT is null: it must count as pending too.
	cfg := load(t, path, `
channels:
  - {title: Rai, url: "https://r", region: IT}
  - {title: BBC, url: "https://b", region: UK}
vpn:
  tunnels:
    IT: ### add IT.conf here
    UK: "### add UK.conf here"
`)
	for _, r := range []string{"IT", "UK"} {
		if _, ok := cfg.VPN.Tunnels[r]; ok {
			t.Errorf("%s resolved with no file", r)
		}
		if want := filepath.Join(dir, "wireguard", r+".conf"); cfg.VPN.Pending[r] != want {
			t.Errorf("Pending[%s] = %q, want %q", r, cfg.VPN.Pending[r], want)
		}
	}

	// The file lands: it is used on the next load, with no save in between.
	touch(t, filepath.Join(dir, "wireguard", "IT.conf"))
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := cfg.VPN.Tunnels["IT"], filepath.Join(dir, "wireguard", "IT.conf"); got != want {
		t.Errorf("IT = %q, want %q", got, want)
	}
	if _, ok := cfg.VPN.Pending["IT"]; ok {
		t.Error("IT still pending after its file appeared")
	}
	if _, ok := cfg.VPN.Pending["UK"]; !ok {
		t.Error("UK should still be pending")
	}
}

func TestPendingRegionCannotEscapeFolder(t *testing.T) {
	if got := pendingPath(filepath.Join(cfgDir(t), "channels.yaml"), "../x"); got != "" {
		t.Errorf("pendingPath for ../x = %q, want none", got)
	}
}

func TestPendingTunnelErrorSaysWhere(t *testing.T) {
	m := newVPNManager(&VPNConfig{Pending: map[string]string{"IT": "/x/wireguard/IT.conf"}})
	_, err := m.tunnelFor("IT")
	if err == nil || !strings.Contains(err.Error(), "/x/wireguard/IT.conf") {
		t.Errorf("error = %v, want one naming the expected path", err)
	}
}

func TestSaveReconcilesTunnels(t *testing.T) {
	dir := cfgDir(t)
	wg := filepath.Join(dir, "wireguard")
	path := filepath.Join(dir, "channels.yaml")
	touch(t, filepath.Join(wg, "IT.conf"))     // was pending: gets its real path
	touch(t, filepath.Join(wg, "FR.conf"))     // unlisted: gets added
	touch(t, filepath.Join(dir, "other.conf")) // real path elsewhere: untouched
	cfg := load(t, path, `
channels:
  - {title: Rai, url: "https://r", region: IT}
  - {title: DE, url: "https://d", region: DE}
vpn:
  tunnels:
    IT: "### add IT.conf here"
    DE: ~/cfg/other.conf
    ES: ~/cfg/gone.conf
`)
	// Added in the panel: a region the file has no entry for (the loader
	// would refuse that in a hand-written file; save fills it in).
	cfg.Channels = append(cfg.Channels, Channel{Title: "BBC", URL: "https://b", Region: "UK"})

	target, warns, err := saveConfig(path, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if target != path {
		t.Errorf("saved to %s", target)
	}

	saved, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("saved file does not load: %v", err)
	}
	want := map[string]string{
		"IT": filepath.Join(wg, "IT.conf"),
		"FR": filepath.Join(wg, "FR.conf"),
		"DE": filepath.Join(dir, "other.conf"),
		"ES": filepath.Join(dir, "gone.conf"), // missing but kept
	}
	for r, p := range want {
		if saved.VPN.Tunnels[r] != p {
			t.Errorf("Tunnels[%s] = %q, want %q", r, saved.VPN.Tunnels[r], p)
		}
	}
	if _, ok := saved.VPN.Pending["UK"]; !ok {
		t.Errorf("UK should be pending, got Tunnels=%v Pending=%v", saved.VPN.Tunnels, saved.VPN.Pending)
	}

	text, _ := os.ReadFile(path)
	if !strings.Contains(string(text), `UK: '### add UK.conf here'`) && !strings.Contains(string(text), `UK: "### add UK.conf here"`) {
		t.Errorf("sentinel not written as a quoted string:\n%s", text)
	}
	if !strings.Contains(string(text), "IT: ~/cfg/wireguard/IT.conf") {
		t.Errorf("real path not written home-relative:\n%s", text)
	}

	joined := strings.Join(warns, "\n")
	if !strings.Contains(joined, "UK") || !strings.Contains(joined, "ES") || strings.Contains(joined, "IT") {
		t.Errorf("warnings = %q, want UK and ES only", warns)
	}
}

func TestSaveKeepsBackupAndRoundTrips(t *testing.T) {
	dir := cfgDir(t)
	path := filepath.Join(dir, "channels.yaml")
	orig := `# my notes
window: {title: Mine, width: 800, height: 600}
media: {seek_seconds: 30, reverse: true}
user_agent: custom/1.0
channels:
  - {title: A, url: "https://a", hide: [".x", ".y"]}
  - {title: B, url: "https://b"}
`
	cfg := load(t, path, orig)
	if _, _, err := saveConfig(path, cfg); err != nil {
		t.Fatal(err)
	}
	if bak, _ := os.ReadFile(path + ".bak"); string(bak) != orig {
		t.Errorf(".bak = %q, want the original", bak)
	}
	again, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if again.Window != cfg.Window || again.Media != cfg.Media || again.UserAgent != "custom/1.0" ||
		len(again.Channels) != 2 || strings.Join(again.Channels[0].Hide, ",") != ".x,.y" || again.VPN != nil {
		t.Errorf("round trip changed the config: %+v", again)
	}
}

func TestSaveRefusesBadConfig(t *testing.T) {
	dir := cfgDir(t)
	path := filepath.Join(dir, "channels.yaml")
	cfg := load(t, path, "channels:\n  - {title: A, url: \"https://a\"}\n")
	cfg.Channels = nil
	if _, _, err := saveConfig(path, cfg); err == nil {
		t.Fatal("saved a config with no channels")
	}
	if got, _ := os.ReadFile(path); !strings.Contains(string(got), "https://a") {
		t.Errorf("failed save damaged the file: %q", got)
	}
}
