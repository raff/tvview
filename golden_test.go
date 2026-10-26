package main

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/golden/*/expected.json from what this build produces")

// The cases in testdata/golden are shared with the Swift app (see the README
// there): the same before-file, the same panel edit, the same expected meaning.
func TestGolden(t *testing.T) {
	cases, err := filepath.Glob("testdata/golden/*/before.yaml")
	if err != nil || len(cases) == 0 {
		t.Fatalf("no golden cases found: %v", err)
	}
	for _, before := range cases {
		dir := filepath.Dir(before)
		t.Run(filepath.Base(dir), func(t *testing.T) { runGolden(t, dir) })
	}
}

func runGolden(t *testing.T, caseDir string) {
	cfgd := cfgDir(t) // also sets HOME to a scratch directory
	path := filepath.Join(cfgd, "channels.yaml")

	text, err := os.ReadFile(filepath.Join(caseDir, "before.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if names, err := os.ReadFile(filepath.Join(caseDir, "wireguard.txt")); err == nil {
		for _, n := range strings.Fields(string(names)) {
			touch(t, filepath.Join(cfgd, "wireguard", n))
		}
	}
	cfg := load(t, path, string(text))

	if raw, err := os.ReadFile(filepath.Join(caseDir, "edit.json")); err == nil {
		var edit panelConfig
		if err := json.Unmarshal(raw, &edit); err != nil {
			t.Fatal(err)
		}
		cfg.Window, cfg.Media, cfg.UserAgent, cfg.Channels = edit.Window, edit.Media, edit.UserAgent, edit.Channels
	}

	_, warns, err := saveConfig(path, cfg)
	if err != nil {
		t.Fatal(err)
	}
	saved, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("saved file does not load: %v", err)
	}

	got := goldenState(t, saved, warns)
	expectedPath := filepath.Join(caseDir, "expected.json")
	if *updateGolden {
		b, _ := json.MarshalIndent(got, "", "  ")
		if err := os.WriteFile(expectedPath, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	var want any
	raw, err := os.ReadFile(expectedPath)
	if err != nil {
		t.Fatalf("%v (run with -update-golden to create it)", err)
	}
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		g, _ := json.MarshalIndent(got, "", "  ")
		w, _ := json.MarshalIndent(want, "", "  ")
		t.Errorf("saved state differs from expected.json\n--- got\n%s\n--- want\n%s", g, w)
	}
}

// goldenState is the meaning of a saved config, as plain JSON values.
func goldenState(t *testing.T, cfg *Config, warns []string) any {
	t.Helper()
	chans := make([]Channel, len(cfg.Channels))
	for i, c := range cfg.Channels {
		if c.Hide == nil {
			c.Hide = []string{}
		}
		chans[i] = c
	}
	var tunnels any
	if cfg.VPN != nil {
		m := map[string]any{}
		for k, v := range cfg.VPN.declared {
			m[k] = v
		}
		tunnels = m
	}
	home := os.Getenv("HOME")
	ws := []string{}
	for _, w := range warns {
		ws = append(ws, strings.ReplaceAll(w, home, "$HOME"))
	}
	sort.Strings(ws)

	b, err := json.Marshal(map[string]any{
		"config":   panelConfig{Window: cfg.Window, Media: cfg.Media, UserAgent: cfg.UserAgent, Channels: chans},
		"tunnels":  tunnels,
		"warnings": ws,
	})
	if err != nil {
		t.Fatal(err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return out
}
