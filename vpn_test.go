package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// newTestVPN returns a manager whose up/down commands append "<verb> <region>"
// to a log file, plus a func to read that log back. Nothing here touches the
// network: what is being tested is the ordering, not the tunnelling.
func newTestVPN(t *testing.T, upExit string) (*vpnManager, func() []string) {
	t.Helper()

	log := filepath.Join(t.TempDir(), "calls")
	script := func(verb, exit string) []string {
		return []string{"/bin/sh", "-c",
			"echo " + verb + " {region} >> " + log + "; exit " + exit}
	}

	m := newVPNManager(&VPNConfig{
		Up:      script("up", upExit),
		Down:    script("down", "0"),
		timeout: 5 * time.Second,
	})

	return m, func() []string {
		data, err := os.ReadFile(log)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			t.Fatalf("reading call log: %v", err)
		}
		return strings.Fields(strings.ReplaceAll(strings.TrimSpace(string(data)), "\n", " | "))
	}
}

func calls(t *testing.T, read func() []string) string {
	t.Helper()
	return strings.Join(read(), " ")
}

func TestVPNEnsureBringsRegionUp(t *testing.T) {
	m, read := newTestVPN(t, "0")

	if err := m.Ensure("IT"); err != nil {
		t.Fatalf("Ensure(IT): %v", err)
	}
	if got := m.Current(); got != "IT" {
		t.Errorf("Current() = %q, want IT", got)
	}
	if got, want := calls(t, read), "up IT"; got != want {
		t.Errorf("calls = %q, want %q", got, want)
	}
}

func TestVPNEnsureIsIdempotent(t *testing.T) {
	m, read := newTestVPN(t, "0")

	for i := range 3 {
		if err := m.Ensure("IT"); err != nil {
			t.Fatalf("Ensure(IT) #%d: %v", i, err)
		}
	}
	// The point of tracking the region: re-selecting a channel on the tunnel
	// already up must not tear it down and rebuild it.
	if got, want := calls(t, read), "up IT"; got != want {
		t.Errorf("calls = %q, want a single %q", got, want)
	}
}

func TestVPNEnsureSwitchingRegionsLowersTheOldOneFirst(t *testing.T) {
	m, read := newTestVPN(t, "0")

	if err := m.Ensure("IT"); err != nil {
		t.Fatalf("Ensure(IT): %v", err)
	}
	if err := m.Ensure("UK"); err != nil {
		t.Fatalf("Ensure(UK): %v", err)
	}

	if got, want := calls(t, read), "up IT | down IT | up UK"; got != want {
		t.Errorf("calls = %q, want %q", got, want)
	}
	if got := m.Current(); got != "UK" {
		t.Errorf("Current() = %q, want UK", got)
	}
}

func TestVPNEnsureEmptyRegionOnlyLowers(t *testing.T) {
	m, read := newTestVPN(t, "0")

	if err := m.Ensure("IT"); err != nil {
		t.Fatalf("Ensure(IT): %v", err)
	}
	if err := m.Ensure(""); err != nil {
		t.Fatalf("Ensure(\"\"): %v", err)
	}

	if got, want := calls(t, read), "up IT | down IT"; got != want {
		t.Errorf("calls = %q, want %q", got, want)
	}
	if got := m.Current(); got != "" {
		t.Errorf("Current() = %q, want empty", got)
	}
}

// A failed `up` must not be remembered as success, or the next switch to that
// region would short-circuit and navigate to an unrouted channel.
func TestVPNEnsureFailedUpLeavesNoRegion(t *testing.T) {
	m, _ := newTestVPN(t, "1")

	err := m.Ensure("IT")
	if err == nil {
		t.Fatal("Ensure(IT) succeeded, want an error from the failing up command")
	}
	if got := m.Current(); got != "" {
		t.Errorf("Current() = %q after a failed up, want empty", got)
	}
}

func TestVPNRunTimesOut(t *testing.T) {
	m := newVPNManager(&VPNConfig{
		Up:      []string{"/bin/sh", "-c", "sleep 5"},
		timeout: 100 * time.Millisecond,
	})

	start := time.Now()
	err := m.Ensure("IT")
	if err == nil {
		t.Fatal("Ensure succeeded, want a timeout")
	}
	if !strings.Contains(err.Error(), "timed out") {
		t.Errorf("error = %v, want it to mention the timeout", err)
	}
	// A blocking `sleep` grandchild does not receive Cancel's SIGINT — only
	// its parent shell does, and a shell already waiting on a foreground
	// child defers its trap until that child exits (see the graceful test
	// below for the case where it does not need to). So this bound has to
	// cover the full escalation: the context timeout, then vpnShutdownGrace
	// before WaitDelay forces it closed regardless.
	if elapsed := time.Since(start); elapsed > 100*time.Millisecond+vpnShutdownGrace+2*time.Second {
		t.Errorf("took %s, want WaitDelay to have bounded it", elapsed)
	}
}

// TestVPNRunSignalsGracefullyBeforeKilling checks the actual point of
// preferring SIGINT to SIGKILL: a script built the way wg-quick is — many
// short steps rather than one long blocking call — gets to run its own INT
// trap and exit cleanly, rather than being killed out from under whatever
// cleanup that trap was going to do.
func TestVPNRunSignalsGracefullyBeforeKilling(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "trapped")

	m := newVPNManager(&VPNConfig{
		Up: []string{"/bin/sh", "-c",
			`trap 'echo caught >> ` + log + `; exit 0' INT TERM
			 i=0; while [ $i -lt 200 ]; do i=$((i+1)); sleep 0.05; done`},
		timeout: 200 * time.Millisecond,
	})

	start := time.Now()
	if err := m.Ensure("IT"); err == nil {
		t.Fatal("Ensure succeeded, want a timeout")
	}
	elapsed := time.Since(start)

	data, err := os.ReadFile(log)
	if err != nil || strings.TrimSpace(string(data)) != "caught" {
		t.Fatalf("trap did not run (log = %q, err = %v); Cancel is not delivering SIGINT the way wg-quick's own cleanup depends on", data, err)
	}
	// The trap exits within one loop iteration (~50ms) of the signal. Nowhere
	// near needing the 5s WaitDelay grace period is the whole point.
	if elapsed > 2*time.Second {
		t.Errorf("took %s to catch the signal and exit, want well under vpnShutdownGrace", elapsed)
	}
}

func TestExpandTilde(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home directory")
	}

	for _, tc := range []struct{ in, want string }{
		{"~/bin/vpn.sh", filepath.Join(home, "bin/vpn.sh")},
		{"/usr/sbin/scutil", "/usr/sbin/scutil"},
		{"wg-quick", "wg-quick"},
		// Only a leading "~/" is a home reference; "~foo" is another user's
		// home to a shell, and expanding it here would be a guess.
		{"~foo/bin", "~foo/bin"},
	} {
		if got := expandTilde(tc.in); got != tc.want {
			t.Errorf("expandTilde(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
