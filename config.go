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

// Channel is one entry in the sidebar. Fields added here are automatically
// available to the sidebar UI via the JSON tags.
type Channel struct {
	Title string `yaml:"title" json:"title"`
	URL   string `yaml:"url"   json:"url"`
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

	channels := cfg.Channels[:0]
	for _, c := range cfg.Channels {
		c.URL = strings.TrimSpace(c.URL)
		c.Title = strings.TrimSpace(c.Title)
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

	return cfg, nil
}

func describePath(path string) string {
	if path == "" {
		return "built-in config"
	}
	return path
}
