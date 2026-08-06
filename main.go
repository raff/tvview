package main

import (
	_ "embed"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"sync"

	"github.com/abemedia/go-webview"
	_ "github.com/abemedia/go-webview/embedded" // embed native library
)

//go:embed sidebar.js
var sidebarJS string

// app holds the state the sidebar needs to survive a navigation. The injected
// script is re-run from scratch on every page load, so it asks Go for this.
type app struct {
	w   webview.WebView
	cfg *Config

	mu      sync.Mutex
	open    bool
	current string
}

func main() {
	configPath := flag.String("config", "", "path to a channels.yaml (default: search ./ then ~/.config/tvview/)")
	debug := flag.Bool("debug", false, "enable developer tools")
	flag.Parse()

	cfg, err := LoadConfig(*configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "tvview:", err)
		os.Exit(1)
	}

	// Nothing was found on disk, so the built-in defaults are in use: leave a
	// copy where the user can find it. An explicit -config means they already
	// know where their config lives, and a config found in the working
	// directory is one too — neither should have a second file appear beside
	// it. Failing to seed is not worth refusing to start over.
	if *configPath == "" && cfg.Path == "" {
		switch path, err := seedUserConfig(); {
		case err != nil:
			fmt.Fprintln(os.Stderr, "tvview: could not write a default config:", err)
		case path != "":
			fmt.Fprintln(os.Stderr, "tvview: wrote a default config to", path)
		}
	}

	w := webview.New(*debug)
	defer w.Destroy()

	a := &app{w: w, cfg: cfg, current: cfg.Channels[0].URL}

	if err := a.bind(); err != nil {
		log.Fatal("tvview: ", err)
	}
	if err := a.inject(); err != nil {
		log.Fatal("tvview: ", err)
	}

	// Must follow New, which is what pulls AppKit into the process.
	if err := installMenuBar(a); err != nil {
		log.Fatal("tvview: ", err)
	}

	w.SetSize(cfg.Window.Width, cfg.Window.Height, webview.HintNone)
	w.SetTitle(a.windowTitle(cfg.Channels[0].URL))
	w.Navigate(cfg.Channels[0].URL)
	w.Run()
}

// bind exposes the sidebar's callbacks. Bindings are re-installed by the
// native webview on every navigation.
func (a *app) bind() error {
	binds := []struct {
		name string
		fn   any
	}{
		// Called once per page load to restore the sidebar's state.
		{"wvState", func() map[string]any {
			a.mu.Lock()
			defer a.mu.Unlock()
			return map[string]any{"open": a.open, "current": a.current}
		}},
		{"wvSelect", func(url string) { a.selectChannel(url) }},
		{"wvSetOpen", func(open bool) {
			a.mu.Lock()
			a.open = open
			a.mu.Unlock()
		}},
	}

	for _, b := range binds {
		if err := a.w.Bind(b.name, b.fn); err != nil {
			return fmt.Errorf("binding %s: %w", b.name, err)
		}
	}
	return nil
}

// inject registers the user scripts: the static channel list first, then the
// sidebar itself.
func (a *app) inject() error {
	boot, err := json.Marshal(map[string]any{"channels": a.cfg.Channels})
	if err != nil {
		return fmt.Errorf("encoding channels: %w", err)
	}

	a.w.Init("window.__WV_BOOT = " + string(boot) + ";")
	a.w.Init(sidebarJS)
	return nil
}

func (a *app) selectChannel(url string) {
	a.mu.Lock()
	a.current = url
	a.mu.Unlock()

	// Never navigate from inside the binding callback.
	a.w.Dispatch(func() {
		a.w.SetTitle(a.windowTitle(url))
		a.w.Navigate(url)
	})
}

// toggleSidebar flips the panel from the menubar. The page owns the animation
// and reports back through wvSetOpen, so a.open stays correct without being
// touched here — exactly the path F9 takes.
func (a *app) toggleSidebar() {
	a.w.Dispatch(func() {
		a.w.Eval("window.wvToggleSidebar && window.wvToggleSidebar();")
	})
}

func (a *app) windowTitle(url string) string {
	for _, c := range a.cfg.Channels {
		if c.URL == url {
			return a.cfg.Window.Title + " — " + c.Title
		}
	}
	return a.cfg.Window.Title
}
