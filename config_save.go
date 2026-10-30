package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// pendingPrefix marks a vpn.tunnels value as "the file for this region isn't
// here yet". The raw file then says what is missing, e.g.
//
//	IT: "### add IT.conf here"
//
// and the entry resolves by itself once wireguard/IT.conf exists. It has to
// be quoted: unquoted, YAML reads `### ...` as a comment and the value as
// null, which the loader treats the same way, so a hand-edited file works too.
const pendingPrefix = "###"

func isPending(v string) bool { return v == "" || strings.HasPrefix(v, pendingPrefix) }

func pendingText(region string) string {
	return pendingPrefix + " add " + region + ".conf here"
}

func isFile(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Mode().IsRegular()
}

// saveTarget is where a config loaded from path is written back. The
// built-in defaults have no path; they go where seeding would put them, which
// is the iCloud folder when that exists (opting in is creating it) and
// ~/.config/tvview otherwise.
func saveTarget(path string) string {
	if path != "" {
		return path
	}
	if dir := iCloudConfigDir(); dir != "" {
		if st, err := os.Stat(dir); err == nil && st.IsDir() {
			return filepath.Join(dir, "channels.yaml")
		}
	}
	if dir := userConfigDir(); dir != "" {
		return filepath.Join(dir, "channels.yaml")
	}
	return ""
}

// wireguardDir is the folder beside the config where region files live.
func wireguardDir(path string) string {
	target := saveTarget(path)
	if target == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(target), "wireguard")
}

// pendingPath is where the file for region is expected, or "" when the region
// name could not safely be one (it must be a bare file name, since a path it
// names is read as a WireGuard config).
func pendingPath(cfgPath, region string) string {
	dir := wireguardDir(cfgPath)
	if dir == "" || region == "" || region != filepath.Base(region) || region == "." || region == ".." {
		return ""
	}
	return filepath.Join(dir, region+".conf")
}

// tildePath is path spelled the way the config spells home-relative paths.
func tildePath(path string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return path
	}
	if rel, err := filepath.Rel(home, path); err == nil && !strings.HasPrefix(rel, "..") {
		return "~/" + filepath.ToSlash(rel)
	}
	return path
}

// reconcileTunnels returns the vpn.tunnels to write for cfg, and warnings for
// what the user has to do by hand. It never removes an entry and never
// rewrites a real path; it only fills in what is missing:
//
//  1. a pending entry whose file now exists gets the real path;
//  2. a NAME.conf in the wireguard folder with no entry gets one;
//  3. a channel region with no entry gets a pending one.
//
// A missing file is a warning, never an error, so a config can be prepared
// before the files are in place.
func reconcileTunnels(cfgPath string, cfg *Config) (map[string]string, []string) {
	out := map[string]string{}
	var warns []string
	if cfg.VPN != nil {
		for k, v := range cfg.VPN.declared {
			out[k] = v
		}
	}
	dir := wireguardDir(cfgPath)

	if dir != "" {
		matches, _ := filepath.Glob(filepath.Join(dir, "*.conf"))
		for _, m := range matches {
			name := strings.TrimSuffix(filepath.Base(m), ".conf")
			if v, ok := out[name]; !ok || isPending(v) {
				out[name] = tildePath(m)
			}
		}
	}

	for _, c := range cfg.Channels {
		if c.Region == "" {
			continue
		}
		if _, ok := out[c.Region]; !ok {
			out[c.Region] = pendingText(c.Region)
		}
	}

	regions := make([]string, 0, len(out))
	for r := range out {
		regions = append(regions, r)
	}
	sort.Strings(regions)
	for _, r := range regions {
		v := out[r]
		switch {
		case isPending(v):
			out[r] = pendingText(r) // canonical, also turns a bare null into text
			where := "the wireguard folder"
			if p := pendingPath(cfgPath, r); p != "" {
				where = p
			}
			warns = append(warns, fmt.Sprintf("region %s has no WireGuard file yet: add %s", r, where))
		case !isFile(expandTilde(v)):
			warns = append(warns, fmt.Sprintf("region %s: %s does not exist", r, v))
		}
	}
	return out, warns
}

// The file layout, in the order a person would write it. Separate from
// Config so that omitting defaults is a property of the file, not of the JSON
// the sidebar sees.
type fileDoc struct {
	Window    WindowConfig `yaml:"window"`
	UserAgent string       `yaml:"user_agent,omitempty"`
	Media     MediaConfig  `yaml:"media"`
	VPN       *fileVPN     `yaml:"vpn,omitempty"`
	Channels  []fileChan   `yaml:"channels"`
}

type fileVPN struct {
	Tunnels map[string]string `yaml:"tunnels"`
}

type fileChan struct {
	Title  string   `yaml:"title"`
	URL    string   `yaml:"url"`
	Region string   `yaml:"region,omitempty"`
	Hide   []string `yaml:"hide,omitempty"`

	RewindButton  string `yaml:"rewind_button,omitempty"`
	ForwardButton string `yaml:"forward_button,omitempty"`
	PlayButton    string `yaml:"play_button,omitempty"`
}

// marshalConfig renders cfg as channels.yaml, with tunnels reconciled. It
// returns the warnings from reconcileTunnels.
func marshalConfig(cfgPath string, cfg *Config) ([]byte, []string, error) {
	doc := fileDoc{Window: cfg.Window, Media: cfg.Media}
	if cfg.UserAgent != defaultUserAgent {
		doc.UserAgent = cfg.UserAgent
	}
	for _, c := range cfg.Channels {
		doc.Channels = append(doc.Channels, fileChan{c.Title, c.URL, c.Region, c.Hide, c.RewindButton, c.ForwardButton, c.PlayButton})
	}

	tunnels, warns := reconcileTunnels(cfgPath, cfg)
	if len(tunnels) > 0 {
		doc.VPN = &fileVPN{Tunnels: tunnels}
	}

	data, err := yaml.Marshal(&doc)
	if err != nil {
		return nil, nil, err
	}
	return data, warns, nil
}

// saveConfig writes cfg to the file it was loaded from (or saveTarget for the
// built-in defaults) and returns the path written plus warnings. Nothing is
// written unless what would be written loads back cleanly, and an existing
// file is kept as path+".bak" first. The write is a rename, so a crash or a
// sync client never sees half a file.
//
// This rewrites the file from structure, so comments in it are not kept; the
// previous version survives in the .bak.
func saveConfig(cfgPath string, cfg *Config) (string, []string, error) {
	target := saveTarget(cfgPath)
	if target == "" {
		return "", nil, fmt.Errorf("nowhere to save the config")
	}

	data, warns, err := marshalConfig(cfgPath, cfg)
	if err != nil {
		return "", nil, err
	}
	if _, err := parseConfig(data, target); err != nil {
		return "", nil, fmt.Errorf("refusing to save: %w", err)
	}

	if err := writeFileAtomic(target, data); err != nil {
		return "", nil, err
	}
	return target, warns, nil
}

// writeFileAtomic replaces target with data, keeping the previous contents as
// target+".bak". The original is copied, never moved, and the new file only
// takes its place by a rename, so a failure at any step leaves it untouched.
func writeFileAtomic(target string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	if old, err := os.Open(target); err == nil {
		err = copyFile(target+".bak", old)
		old.Close()
		if err != nil {
			return fmt.Errorf("writing backup: %w", err)
		}
	}

	tmp, err := os.CreateTemp(filepath.Dir(target), ".channels-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), target)
}

func copyFile(dst string, src io.Reader) error {
	f, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, src); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
