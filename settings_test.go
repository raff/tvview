package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func panelApp(t *testing.T, text string) (*app, string) {
	t.Helper()
	dir := cfgDir(t)
	path := filepath.Join(dir, "channels.yaml")
	cfg := load(t, path, text)
	return &app{cfg: cfg, vpn: newVPNManager(cfg.VPN), current: cfg.Channels[0].URL}, dir
}

func req(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestConfigViewHidesPaths(t *testing.T) {
	a, dir := panelApp(t, `
channels:
  - {title: Rai, url: "https://r", region: IT}
vpn:
  tunnels:
    IT: "### add IT.conf here"
`)
	touch(t, filepath.Join(dir, "wireguard", "FR.conf"))

	view := a.configView()
	regions := view["regions"].([]regionInfo)
	got := map[string]string{}
	for _, r := range regions {
		got[r.Name] = r.State
	}
	if got["IT"] != "pending" || got["FR"] != "ok" || len(got) != 2 {
		t.Errorf("regions = %v", got)
	}
	// Warnings may say where to put a file (display only, nothing reads
	// them back); the editable parts must carry no path.
	b, _ := json.Marshal([]any{view["config"], view["regions"]})
	if strings.Contains(string(b), dir) || strings.Contains(string(b), ".conf") {
		t.Errorf("config or regions leak a path: %s", b)
	}
}

func TestSaveFromPanelStructured(t *testing.T) {
	a, dir := panelApp(t, `
window: {title: T, width: 800, height: 600}
channels:
  - {title: A, url: "https://a"}
  - {title: B, url: "https://b"}
`)
	res := a.saveFromPanel(req(t, map[string]any{"config": map[string]any{
		"window": map[string]any{"title": "New", "width": 900, "height": 600},
		"media":  map[string]any{"seekSeconds": 15, "reverse": false},
		"channels": []any{
			map[string]any{"title": "B", "url": "https://b", "hide": []string{".x"}},
			map[string]any{"title": "C", "url": "https://c", "region": "IT"},
		},
	}}))
	if res["ok"] != true {
		t.Fatalf("save failed: %v", res)
	}

	if got := a.cfg.Channels; len(got) != 2 || got[0].Title != "B" || got[1].Region != "IT" {
		t.Errorf("live channels = %+v", got)
	}
	if a.cfg.Window.Title != "New" || a.cfg.Media.SeekSeconds != 15 {
		t.Errorf("live config not updated: %+v", a.cfg)
	}
	restart, _ := res["restart"].([]string)
	joined := strings.Join(restart, ",")
	for _, want := range []string{"window size", "media settings", "hidden page elements", "VPN regions"} {
		if !strings.Contains(joined, want) {
			t.Errorf("restart = %q, missing %q", joined, want)
		}
	}
	warns, _ := res["warnings"].([]string)
	if len(warns) != 1 || !strings.Contains(warns[0], "IT") {
		t.Errorf("warnings = %q, want one about IT", warns)
	}

	text, _ := os.ReadFile(filepath.Join(dir, "channels.yaml"))
	if !strings.Contains(string(text), "add IT.conf here") {
		t.Errorf("pending entry not written:\n%s", text)
	}
}

func TestSaveFromPanelRejects(t *testing.T) {
	a, dir := panelApp(t, "channels:\n  - {title: A, url: \"https://a\"}\n")
	before, _ := os.ReadFile(filepath.Join(dir, "channels.yaml"))

	for name, body := range map[string]any{
		"no url":      map[string]any{"config": map[string]any{"channels": []any{map[string]any{"title": "x", "url": " "}}}},
		"no channels": map[string]any{"config": map[string]any{"channels": []any{}}},
		"bad raw":     map[string]any{"raw": "channels: ["},
		"empty":       map[string]any{},
	} {
		res := a.saveFromPanel(req(t, body))
		if res["ok"] != false || res["error"] == "" {
			t.Errorf("%s: res = %v, want a refusal", name, res)
		}
	}
	after, _ := os.ReadFile(filepath.Join(dir, "channels.yaml"))
	if string(before) != string(after) || len(a.cfg.Channels) != 1 {
		t.Error("a refused save changed the file or the live config")
	}
}

func TestSaveFromPanelRaw(t *testing.T) {
	a, dir := panelApp(t, "channels:\n  - {title: A, url: \"https://a\"}\n")
	raw := "# keep me\nchannels:\n  - {title: Z, url: \"https://z\"}\n"
	res := a.saveFromPanel(req(t, map[string]any{"raw": raw}))
	if res["ok"] != true {
		t.Fatalf("res = %v", res)
	}
	if got, _ := os.ReadFile(filepath.Join(dir, "channels.yaml")); string(got) != raw {
		t.Errorf("raw save rewrote the text:\n%s", got)
	}
	if a.cfg.Channels[0].Title != "Z" {
		t.Errorf("live channels = %+v", a.cfg.Channels)
	}
}
