//go:build darwin

package main

import (
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// testWireguardConf is a syntactically valid but unreachable wireguard
// config — a TEST-NET-3 (RFC 5737) endpoint that will never answer, and a
// key pair that's the right shape (32 random bytes, base64) without being a
// real registered peer. Its content no longer matters to these tests (see
// newTestVPN's raiseKernelTunnel stub below) but a real path still needs to
// exist for tunnelFor's own map lookup.
const testWireguardConf = `[Interface]
PrivateKey = SBt3+xy10Mo/W2vcUvJ2Bg8UvW1FDcCzM53s3Nz+t0M=
Address = 10.200.200.2/32

[Peer]
PublicKey = 5UWn/wdKpxPvIV5A18JZWJUW1zGlXCJmXaR0S5ohNzM=
Endpoint = 203.0.113.1:51820
AllowedIPs = 0.0.0.0/0
`

// newTestVPN stubs out both the WKWebView proxy calls and the actual
// tunnel-raising: the real path needs a one-time admin-privilege prompt
// (vpnhelper) and a live WireGuard peer, neither of which a `go test` run
// can provide. The fake tunnel it substitutes still binds a real port, so
// tests that check port lifecycle (e.g. TestVPNCloseFreesTheSocks5Port)
// still exercise real behavior.
func newTestVPN(t *testing.T, tunnels map[string]string) *vpnManager {
	t.Helper()

	setter, clearer := webViewProxySetter, webViewProxyClearer
	webViewProxySetter = func(int) error { return nil }
	webViewProxyClearer = func() error { return nil }
	t.Cleanup(func() { webViewProxySetter, webViewProxyClearer = setter, clearer })

	raise := raiseKernelTunnel
	raiseKernelTunnel = func(string) (*regionTunnelKernel, error) {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return nil, err
		}
		return &regionTunnelKernel{ln: ln, port: ln.Addr().(*net.TCPAddr).Port}, nil
	}
	t.Cleanup(func() { raiseKernelTunnel = raise })

	m := newVPNManager(&VPNConfig{Tunnels: tunnels})
	t.Cleanup(m.Close)
	return m
}

func writeTestConf(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "IT.conf")
	if err := os.WriteFile(path, []byte(testWireguardConf), 0o644); err != nil {
		t.Fatalf("writing test conf: %v", err)
	}
	return path
}

func TestVPNEnsureStartsAndRemembersRegion(t *testing.T) {
	m := newTestVPN(t, map[string]string{"IT": writeTestConf(t)})

	if err := m.Ensure("IT"); err != nil {
		t.Fatalf("Ensure(IT): %v", err)
	}
	if got := m.Current(); got != "IT" {
		t.Errorf("Current() = %q, want IT", got)
	}
	if _, ok := m.started["IT"]; !ok {
		t.Errorf("IT's tunnel was not recorded as started")
	}
}

func TestVPNEnsureIsIdempotent(t *testing.T) {
	m := newTestVPN(t, map[string]string{"IT": writeTestConf(t)})

	if err := m.Ensure("IT"); err != nil {
		t.Fatalf("Ensure(IT): %v", err)
	}
	rt := m.started["IT"]

	if err := m.Ensure("IT"); err != nil {
		t.Fatalf("second Ensure(IT): %v", err)
	}
	if m.started["IT"] != rt {
		t.Errorf("Ensure(IT) a second time started a new tunnel instead of reusing the existing one")
	}
}

func TestVPNEnsureReusesTunnelAcrossSwitches(t *testing.T) {
	confIT, confUK := writeTestConf(t), writeTestConf(t)
	m := newTestVPN(t, map[string]string{"IT": confIT, "UK": confUK})

	if err := m.Ensure("IT"); err != nil {
		t.Fatalf("Ensure(IT): %v", err)
	}
	itTunnel := m.started["IT"]

	if err := m.Ensure(""); err != nil {
		t.Fatalf("Ensure(\"\"): %v", err)
	}
	if got := m.Current(); got != "" {
		t.Errorf("Current() = %q, want empty after Ensure(\"\")", got)
	}
	if _, ok := m.started["IT"]; !ok {
		t.Errorf("switching away from IT tore its tunnel down; it should stay resident")
	}

	if err := m.Ensure("IT"); err != nil {
		t.Fatalf("re-Ensure(IT): %v", err)
	}
	if m.started["IT"] != itTunnel {
		t.Errorf("switching back to IT started a new tunnel instead of reusing the resident one")
	}
}

func TestVPNEnsureUnknownRegion(t *testing.T) {
	m := newTestVPN(t, map[string]string{"IT": writeTestConf(t)})

	if err := m.Ensure("UK"); err == nil {
		t.Fatalf("Ensure(UK) with no matching tunnel: want error, got nil")
	}
}

func TestVPNCloseFreesTheSocks5Port(t *testing.T) {
	m := newTestVPN(t, map[string]string{"IT": writeTestConf(t)})

	if err := m.Ensure("IT"); err != nil {
		t.Fatalf("Ensure(IT): %v", err)
	}
	port := m.started["IT"].port

	m.Close()

	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		t.Fatalf("port %d still bound after Close: %v", port, err)
	}
	ln.Close()
}
