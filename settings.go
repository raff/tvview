package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"sort"
	"strings"
)

//go:embed settings.js
var settingsJS string

// What settings.js sends back. The same types and JSON tags as the config
// itself, so the panel and the sidebar see one shape.
type panelConfig struct {
	Window    WindowConfig `json:"window"`
	Media     MediaConfig  `json:"media"`
	UserAgent string       `json:"user_agent"`
	Channels  []Channel    `json:"channels"`
}

type saveRequest struct {
	Raw    *string      `json:"raw"`
	Config *panelConfig `json:"config"`
}

type regionInfo struct {
	Name  string `json:"name"`
	State string `json:"state"` // ok, pending or missing
}

// current is a copy of the live config. Callers must not hold a.mu.
func (a *app) snapshot() Config {
	a.mu.Lock()
	defer a.mu.Unlock()
	return *a.cfg
}

// channelList is the live channel list, safe to read while a save swaps it.
func (a *app) channelList() []Channel {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.cfg.Channels
}

// configView is what the panel opens with. Region names and states only: the
// panel never sees, and so can never send back, a path.
func (a *app) configView() map[string]any {
	cur := a.snapshot()
	target := saveTarget(cur.Path)

	raw := string(defaultConfig)
	if data, err := os.ReadFile(target); err == nil {
		raw = string(data)
	}

	tunnels, warns := reconcileTunnels(cur.Path, &cur)
	regions := make([]regionInfo, 0, len(tunnels))
	for name, v := range tunnels {
		state := "ok"
		switch {
		case isPending(v):
			state = "pending"
		case !isFile(expandTilde(v)):
			state = "missing"
		}
		regions = append(regions, regionInfo{name, state})
	}
	sort.Slice(regions, func(i, j int) bool { return regions[i].Name < regions[j].Name })

	return map[string]any{
		"config": panelConfig{
			Window:    cur.Window,
			Media:     cur.Media,
			UserAgent: cur.UserAgent,
			Channels:  cur.Channels,
		},
		"defaultUserAgent": defaultUserAgent,
		"regions":          regions,
		"raw":              raw,
		"path":             describePath(target),
		"warnings":         warns,
	}
}

// saveFromPanel applies a request from settings.js. It returns the same shape
// whether it worked or not, since the page only gets one return value.
func (a *app) saveFromPanel(js string) map[string]any {
	fail := func(err error) map[string]any {
		return map[string]any{"ok": false, "error": err.Error()}
	}

	var req saveRequest
	if err := json.Unmarshal([]byte(js), &req); err != nil {
		return fail(fmt.Errorf("bad request: %w", err))
	}

	old := a.snapshot()
	var warns []string
	var target string

	switch {
	case req.Raw != nil:
		target = saveTarget(old.Path)
		data := []byte(*req.Raw)
		if _, err := parseConfig(data, target); err != nil {
			return fail(err)
		}
		if err := writeFileAtomic(target, data); err != nil {
			return fail(err)
		}

	case req.Config != nil:
		next := old
		next.Window = req.Config.Window
		next.Media = req.Config.Media
		next.UserAgent = req.Config.UserAgent
		next.Channels = req.Config.Channels
		for i, c := range next.Channels {
			if strings.TrimSpace(c.URL) == "" {
				return fail(fmt.Errorf("channel %d (%q) has no URL", i+1, c.Title))
			}
		}
		var err error
		if target, warns, err = saveConfig(old.Path, &next); err != nil {
			return fail(err)
		}

	default:
		return fail(fmt.Errorf("nothing to save"))
	}

	// Reload from the file rather than trusting what was sent: this is the
	// config the next launch will see, defaults and tunnels included.
	fresh, err := LoadConfig(target)
	if err != nil {
		return fail(err)
	}

	a.mu.Lock()
	a.cfg = fresh
	a.mu.Unlock()

	a.applySaved(old, fresh)

	return map[string]any{"ok": true, "warnings": warns, "restart": restartReasons(a, old, fresh)}
}

// applySaved pushes what can change in a running app: the window title, the
// user agent (from the next page load), and the Channels menu.
func (a *app) applySaved(old Config, fresh *Config) {
	if a.w == nil { // tests have no web view
		return
	}
	a.mu.Lock()
	url := a.current
	a.mu.Unlock()

	a.w.Dispatch(func() {
		a.w.SetTitle(a.windowTitle(url))
		if fresh.UserAgent != old.UserAgent {
			a.setUserAgent(fresh.UserAgent)
		}
		refreshChannelsMenu(a)
	})
}

// restartReasons names the saved changes that only take effect on the next
// launch, because the thing they configure was built once at startup: user
// scripts are injected once (hide selectors, media), the window is sized once,
// and the VPN manager is made from the tunnels as they were.
func restartReasons(a *app, old Config, fresh *Config) []string {
	var r []string
	if old.Window.Width != fresh.Window.Width || old.Window.Height != fresh.Window.Height {
		r = append(r, "window size")
	}
	if old.Media != fresh.Media {
		r = append(r, "media settings")
	}
	if !sameHide(old.Channels, fresh.Channels) {
		r = append(r, "hidden page elements")
	}
	if vpnChanged(a, fresh) {
		r = append(r, "VPN regions")
	}
	return r
}

func sameHide(a, b []Channel) bool {
	hide := func(cs []Channel) map[string]string {
		m := map[string]string{}
		for _, c := range cs {
			m[c.URL] = strings.Join(c.Hide, "\n")
		}
		return m
	}
	return reflect.DeepEqual(hide(a), hide(b))
}

// vpnChanged is whether the running tunnel manager would differ from one made
// from fresh. The manager keeps what it was built with, so any difference in
// regions or in where their files are needs a restart.
func vpnChanged(a *app, fresh *Config) bool {
	if a.vpn == nil || fresh.VPN == nil {
		return (a.vpn == nil) != (fresh.VPN == nil)
	}
	return !reflect.DeepEqual(a.vpn.tunnels, fresh.VPN.Tunnels) ||
		!reflect.DeepEqual(a.vpn.pending, fresh.VPN.Pending)
}

// openSettings shows the panel in the current page, for the menu and shortcut.
func (a *app) openSettings() {
	a.w.Dispatch(func() {
		a.w.Eval("window.wvOpenSettings && window.wvOpenSettings();")
	})
}
