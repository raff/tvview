package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// vpnShutdownGrace bounds how long a timed-out command is given to exit after
// being asked nicely, before Cancel escalates to killing it outright.
const vpnShutdownGrace = 5 * time.Second

// vpnManager runs the configured up/down commands and remembers which region
// it believes is currently up.
//
// It deliberately knows nothing about VPNs. Every protocol worth using here is
// reachable as "run this command and wait for exit 0" — wg-quick, scutil, a
// shell script of your own — and the one thing they do not share is a way to
// ask "which region am I on?" that is both cheap and reliable. So the region
// is tracked in this process rather than probed, and the cost of that choice
// is stated where it lands: see Current.
type vpnManager struct {
	cfg *VPNConfig

	mu     sync.Mutex
	region string
}

func newVPNManager(cfg *VPNConfig) *vpnManager {
	if cfg == nil {
		return nil
	}
	return &vpnManager{cfg: cfg}
}

// Current is the region this process last brought up, or "" for none.
//
// It is what we believe, not what the machine is doing: a tunnel raised by the
// Proton app, or left over from a previous run, is invisible to us and reads as
// "". The failure that follows is a redundant `up` on a region already routed,
// which every backend worth using treats as a no-op. That is the whole reason
// this is a belief and not a probe.
func (m *vpnManager) Current() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.region
}

// Ensure makes region the active tunnel, bringing down whatever this process
// raised before it. An empty region means "no tunnel" and only tears down.
//
// The lock is held across the command runs, so two channel switches in quick
// succession queue rather than interleave — a half-raised Italy and a
// half-raised UK racing each other is not a state worth being able to reach.
// Callers therefore must not run this on the UI thread.
func (m *vpnManager) Ensure(region string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.region == region {
		return nil
	}

	if m.region != "" {
		// A failed teardown is reported but not fatal. The usual cause is a
		// tunnel that is already gone, and refusing to raise the next region
		// because the last one could not be lowered twice would strand the
		// user on the channel they are trying to leave.
		if err := m.run(m.cfg.Down, m.region); err != nil {
			fmt.Fprintf(os.Stderr, "tvview: bringing %s down: %v\n", m.region, err)
		}
		m.region = ""
	}

	if region == "" {
		return nil
	}

	if err := m.run(m.cfg.Up, region); err != nil {
		// m.region stays "" — the tunnel is not up, and claiming otherwise
		// would suppress the retry on the next switch to this region.
		return err
	}
	m.region = region
	return nil
}

// run executes argv with {region} substituted, and waits for it.
func (m *vpnManager) run(argv []string, region string) error {
	if len(argv) == 0 {
		return nil
	}

	args := make([]string, len(argv))
	for i, s := range argv {
		args[i] = strings.ReplaceAll(s, "{region}", region)
	}
	args[0] = expandTilde(args[0])

	ctx, cancel := context.WithTimeout(context.Background(), m.cfg.timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	// wg-quick's own INT/TERM trap is what runs its cleanup — including
	// waking the detached background process that restores DNS on macOS (see
	// README, "Watching from another country"). The default Cancel is
	// SIGKILL, which a script cannot trap: a timeout would bypass that
	// cleanup entirely and hand the next run a half-torn-down interface or a
	// DNS override nothing will ever undo. Ask first; WaitDelay still bounds
	// the wait if it doesn't listen.
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = vpnShutdownGrace

	out, err := cmd.CombinedOutput()

	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Errorf("%s timed out after %s", args[0], m.cfg.timeout)
	}
	if err != nil {
		// A bundled app inherits a minimal PATH from Finder — no Homebrew,
		// no /usr/local/bin — so a bare `wg-quick` that works in a terminal
		// is not found here. It is the first thing to suspect, and the bare
		// exec error does not say so.
		if _, ok := err.(*exec.Error); ok && !strings.ContainsRune(args[0], '/') {
			return fmt.Errorf("%s: %w (try an absolute path: a bundled app's PATH does not include Homebrew)", args[0], err)
		}
		return fmt.Errorf("%s: %w%s", args[0], err, describeOutput(out))
	}
	return nil
}

// describeOutput renders a command's output for an error message, or "" when
// it said nothing useful.
func describeOutput(out []byte) string {
	s := strings.TrimSpace(string(out))
	if s == "" {
		return ""
	}
	// One line is enough for a status overlay; wg-quick in particular narrates
	// every route it installs before it gets to the part that failed.
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		s = s[i+1:]
	}
	return ": " + strings.TrimSpace(s)
}

// expandTilde resolves a leading ~/ so config files can point at a script in
// the home directory. Nothing here runs through a shell, so without this the
// tilde would be taken literally and the command simply not found.
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
