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

	start := cfg.Channels[0].URL
	if last := loadLastChannel(); last != "" {
		for _, c := range cfg.Channels {
			if c.URL == last {
				start = last
				break
			}
		}
	}

	a := &app{w: w, cfg: cfg, current: start}

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

	// Before the first Navigate, and before anything can go fullscreen: the
	// web view needs a container to be pulled out of and put back into.
	if !a.hostWebView() {
		fmt.Fprintln(os.Stderr, "tvview: could not re-home the web view; fullscreen may leave the window wrong")
	}

	// Before the first Navigate: the User-Agent is read as the page loads.
	// Not fatal if it does not take — the app is still usable, just back to
	// stalling on the channels that made us want this.
	if !a.setUserAgent(cfg.UserAgent) {
		fmt.Fprintln(os.Stderr, "tvview: could not set the user agent; using the web view's own")
	} else if *debug {
		fmt.Fprintln(os.Stderr, "tvview: user agent:", cfg.UserAgent)
	}

	w.SetSize(cfg.Window.Width, cfg.Window.Height, webview.HintNone)
	w.SetTitle(a.windowTitle(start))
	w.Navigate(start)
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

// stepChannel moves to the next (delta 1) or previous (delta -1) channel,
// wrapping around the ends of the list.
func (a *app) stepChannel(delta int) {
	channels := a.cfg.Channels
	a.mu.Lock()
	i := 0
	for j, c := range channels {
		if c.URL == a.current {
			i = j
			break
		}
	}
	i = (i + delta + len(channels)) % len(channels)
	a.mu.Unlock()

	a.selectChannel(channels[i].URL)
}

func (a *app) selectChannel(url string) {
	a.mu.Lock()
	a.current = url
	a.mu.Unlock()

	saveLastChannel(url)

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
