package main

import (
	_ "embed"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// defaultConfig is used when no config file is found on disk, so the app
// always starts with something to show.
//
//go:embed channels.yaml
var defaultConfig []byte

// defaultUserAgent is what the web view claims to be when the config does not
// say otherwise. It is Safari's string, and it is deliberately Safari's:
// streaming sites branch hard on the User-Agent, and the stock WKWebView one
// is not Safari's, so they hand us the media path that stalls (see NOTES.md).
// The engine underneath really is Safari's, so this is a truthful enough claim
// as these things go.
//
// The AppleWebKit token has been frozen at 605.1.15 for years; only Version/
// tracks the Safari release, and sites care about it far less than about the
// word "Safari" being there at all. Override user_agent in the config to match
// this machine exactly.
const defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
	"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15"

// Channel is one entry in the sidebar. Fields added here are automatically
// available to the sidebar UI via the JSON tags.
type Channel struct {
	Title string `yaml:"title" json:"title"`
	URL   string `yaml:"url"   json:"url"`

	// Region is the VPN region this channel needs, which must match a key
	// in vpn.tunnels. Empty means the channel is watched without a tunnel.
	// Meaningless without a vpn block, which parseConfig rejects rather
	// than silently ignores.
	Region string `yaml:"region" json:"region"`
}

// VPNConfig maps each VPN region to the wireguard config file that raises
// its tunnel. See vpn_wireproxy_darwin.go: each tunnel is a userspace
// WireGuard client (via the embedded wireproxy library) exposed only as a
// local SOCKS5 proxy that this app's WKWebViews are pointed at — no root,
// no system routes.
type VPNConfig struct {
	// Tunnels maps a region name (matched against Channel.Region) to a
	// wireguard .conf file — the same [Interface]/[Peer] file downloaded
	// from the VPN provider, unmodified.
	Tunnels map[string]string `yaml:"tunnels" json:"-"`
}

// WindowConfig controls the host window.
type WindowConfig struct {
	Title  string `yaml:"title"  json:"title"`
	Width  int    `yaml:"width"  json:"width"`
	Height int    `yaml:"height" json:"height"`
}

// Config is the whole channels.yaml document.
type Config struct {
	Window   WindowConfig `yaml:"window"   json:"window"`
	Channels []Channel    `yaml:"channels" json:"channels"`

	// VPN is nil when the file has no vpn block, which is what switches the
	// whole feature off.
	VPN *VPNConfig `yaml:"vpn" json:"-"`

	// UserAgent is what the web view reports to sites. Empty means
	// defaultUserAgent — an older config with no user_agent key still gets
	// the current default rather than the stock WKWebView string.
	UserAgent string `yaml:"user_agent" json:"user_agent"`

	// Path is where the config was read from, or "" when the built-in
	// defaults were used. Not part of the file itself.
	Path string `yaml:"-" json:"path"`
}

// LoadConfig reads the config from path when given, otherwise from the first
// location in the search order that exists, falling back to the built-in
// defaults.
func LoadConfig(path string) (*Config, error) {
	if path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		return parseConfig(data, path)
	}

	for _, p := range configSearchPaths() {
		data, err := os.ReadFile(p)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		return parseConfig(data, p)
	}

	return parseConfig(defaultConfig, "")
}

// userConfigDir is where a user's own config lives, or "" when not even the
// home directory can be determined. XDG rather than ~/Library/Application
// Support: this is a config file people are meant to open in an editor.
func userConfigDir() string {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "tvview")
}

// configSearchPaths lists the candidate config locations, most specific first.
func configSearchPaths() []string {
	paths := []string{"channels.yaml", "channels.yml"}

	if dir := userConfigDir(); dir != "" {
		paths = append(paths,
			filepath.Join(dir, "channels.yaml"),
			filepath.Join(dir, "channels.yml"),
		)
	}

	return paths
}

// seedUserConfig writes the built-in defaults into the user's config directory,
// so that a first run leaves an obvious file to edit rather than a config that
// exists only inside the binary. This matters most for a bundled app, where
// there is no project directory to look in.
//
// It returns the path it wrote, or "" if a file was already there. Never
// overwrites: an existing file is the user's, whatever it contains.
func seedUserConfig() (string, error) {
	dir := userConfigDir()
	if dir == "" {
		return "", errors.New("no home directory")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	// O_EXCL rather than checking first: the check-then-write habit is not
	// worth forming, even where nothing else is racing us.
	path := filepath.Join(dir, "channels.yaml")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if errors.Is(err, fs.ErrExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}

	if _, err := f.Write(defaultConfig); err != nil {
		f.Close()
		return "", err
	}
	if err := f.Close(); err != nil {
		return "", err
	}

	return path, nil
}

// lastChannelPath is where the most recently viewed channel's URL is
// remembered across restarts, or "" when there is nowhere to put it.
func lastChannelPath() string {
	dir := userConfigDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, "last_channel")
}

// loadLastChannel returns the previously saved channel URL, or "" if none was
// saved yet or it can't be read.
func loadLastChannel() string {
	path := lastChannelPath()
	if path == "" {
		return ""
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// saveLastChannel remembers url for next launch. Failures are not fatal to a
// channel switch, so they're only logged.
func saveLastChannel(url string) {
	path := lastChannelPath()
	if path == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "tvview: could not save last channel:", err)
		return
	}
	if err := os.WriteFile(path, []byte(url), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "tvview: could not save last channel:", err)
	}
}

func parseConfig(data []byte, path string) (*Config, error) {
	cfg := &Config{Path: path}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", describePath(path), err)
	}

	if cfg.Window.Title == "" {
		cfg.Window.Title = "TV View"
	}
	if cfg.Window.Width <= 0 {
		cfg.Window.Width = 1200
	}
	if cfg.Window.Height <= 0 {
		cfg.Window.Height = 900
	}

	cfg.UserAgent = strings.TrimSpace(cfg.UserAgent)
	if cfg.UserAgent == "" {
		cfg.UserAgent = defaultUserAgent
	}

	channels := cfg.Channels[:0]
	for _, c := range cfg.Channels {
		c.URL = strings.TrimSpace(c.URL)
		c.Title = strings.TrimSpace(c.Title)
		c.Region = strings.TrimSpace(c.Region)
		if c.URL == "" {
			continue
		}
		if c.Title == "" {
			c.Title = c.URL
		}
		channels = append(channels, c)
	}
	cfg.Channels = channels

	if len(cfg.Channels) == 0 {
		return nil, fmt.Errorf("%s defines no channels with a url", describePath(path))
	}

	if err := cfg.checkVPN(path); err != nil {
		return nil, err
	}

	return cfg, nil
}

// checkVPN validates the vpn block against the channels that reference it.
//
// A region with no vpn block is a config mistake that would otherwise fail
// silently — the channel loads, unrouted, and looks exactly like a geo-block
// from the site. Refusing to start is the kinder answer, especially for a
// bundled app where nobody is watching stderr.
func (cfg *Config) checkVPN(path string) error {
	if cfg.VPN == nil {
		for _, c := range cfg.Channels {
			if c.Region != "" {
				return fmt.Errorf("%s: channel %q sets region %q but the file has no vpn block",
					describePath(path), c.Title, c.Region)
			}
		}
		return nil
	}

	if len(cfg.VPN.Tunnels) == 0 {
		return fmt.Errorf("%s: vpn needs at least one entry under tunnels", describePath(path))
	}

	resolved := make(map[string]string, len(cfg.VPN.Tunnels))
	for region, p := range cfg.VPN.Tunnels {
		resolved[region] = expandTilde(strings.TrimSpace(p))
	}
	cfg.VPN.Tunnels = resolved

	// A region with no matching tunnel is a config mistake that would
	// otherwise fail deep inside vpnManager instead of at startup — same
	// reasoning as the no-vpn-block case above.
	used := false
	for _, c := range cfg.Channels {
		if c.Region == "" {
			continue
		}
		used = true
		if _, ok := cfg.VPN.Tunnels[c.Region]; !ok {
			return fmt.Errorf("%s: channel %q sets region %q but vpn.tunnels has no entry for it",
				describePath(path), c.Title, c.Region)
		}
	}
	// A vpn block no channel uses is more likely a half-finished edit than an
	// intention, and it costs nothing to say so.
	if !used {
		fmt.Fprintf(os.Stderr, "tvview: %s configures a vpn but no channel sets a region\n", describePath(path))
	}
	return nil
}

// expandTilde resolves a leading ~/ so channels.yaml can point a wireguard
// config at a file in the home directory, e.g. ~/.config/tvview/IT.conf.
func expandTilde(path string) string {
	if !strings.HasPrefix(path, "~/") {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	return filepath.Join(home, path[2:])
}

func describePath(path string) string {
	if path == "" {
		return "built-in config"
	}
	return path
}
