//go:build darwin

package main

import (
	"fmt"
	"net"
	"os"
	"sync"

	"github.com/things-go/go-socks5"
	"github.com/things-go/go-socks5/bufferpool"
	"github.com/windtf/wireproxy"
	"golang.zx2c4.com/wireguard/device"
)

// vpnManager owns one userspace WireGuard tunnel per region (via the
// embedded wireproxy library), each exposed as a local SOCKS5 proxy, and
// points [WKWebsiteDataStore defaultDataStore] (vpn_proxy_darwin.go) at
// whichever one is current. No root, no system routes, no wg-quick — see
// README, "Watching from another country".
//
// A tunnel is started lazily on first use and then left running until the
// process exits; Ensure never tears one down on a channel switch. The old
// command-runner backend's Down/auto_disconnect existed only because a
// system-wide tunnel outliving its channel quietly routed unrelated
// traffic through another country. That risk is gone once nothing but this
// one data store is ever proxied, so there's nothing left to protect
// against by tearing a tunnel down early — leaving Italy's and the UK's
// both resident costs an occasional WireGuard keepalive each, not system
// state.
type vpnManager struct {
	tunnels map[string]string // region -> wireguard .conf path, from VPNConfig.Tunnels

	mu      sync.Mutex
	started map[string]*regionTunnel
	current string
}

type regionTunnel struct {
	vt   *wireproxy.VirtualTun
	ln   net.Listener
	port int
}

// webViewProxySetter/webViewProxyClearer indirect setWebViewProxy/
// clearWebViewProxy (vpn_proxy_darwin.go) so tests can substitute a stub:
// the real functions need WKWebsiteDataStore already loaded via WebKit,
// which a bare `go test` binary never does since nothing creates a
// WKWebView.
var (
	webViewProxySetter  = setWebViewProxy
	webViewProxyClearer = clearWebViewProxy
)

func newVPNManager(cfg *VPNConfig) *vpnManager {
	if cfg == nil {
		return nil
	}
	return &vpnManager{tunnels: cfg.Tunnels, started: map[string]*regionTunnel{}}
}

// Current is the region the WKWebView proxy is pointed at, or "" for none.
func (m *vpnManager) Current() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.current
}

// Ensure makes region the one the WKWebView proxy points at, starting its
// tunnel on first use. An empty region clears the proxy without touching
// any tunnel — there's nothing to tear down, see the type comment.
func (m *vpnManager) Ensure(region string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.current == region {
		return nil
	}

	if region == "" {
		if err := webViewProxyClearer(); err != nil {
			return err
		}
		m.current = ""
		return nil
	}

	rt, err := m.tunnelFor(region)
	if err != nil {
		return err
	}
	if err := webViewProxySetter(rt.port); err != nil {
		return err
	}
	m.current = region
	return nil
}

// tunnelFor returns region's tunnel, starting it on first use. Called with
// mu held.
func (m *vpnManager) tunnelFor(region string) (*regionTunnel, error) {
	if rt, ok := m.started[region]; ok {
		return rt, nil
	}

	path, ok := m.tunnels[region]
	if !ok {
		return nil, fmt.Errorf("no wireguard config for region %q", region)
	}

	conf, err := wireproxy.ParseConfig(path)
	if err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}

	vt, err := wireproxy.StartWireguard(conf, device.LogLevelError)
	if err != nil {
		return nil, fmt.Errorf("starting wireguard for %s: %w", region, err)
	}

	ln, port, err := spawnSocks5(vt)
	if err != nil {
		vt.Dev.Close()
		return nil, fmt.Errorf("starting socks5 proxy for %s: %w", region, err)
	}

	rt := &regionTunnel{vt: vt, ln: ln, port: port}
	m.started[region] = rt
	return rt, nil
}

// spawnSocks5 starts a SOCKS5 server tunneled through vt on a free local
// port. This mirrors wireproxy.Socks5Config.SpawnRoutine, but binds the
// listener here first instead of handing wireproxy a bind address:
// SpawnRoutine calls log.Fatal on a listen failure, which would take the
// whole app down over what's usually just an unlucky ephemeral-port race.
// Binding ourselves also means the user's wireguard .conf needs no
// [Socks5] section at all — just the bare [Interface]/[Peer] exactly as
// downloaded from the VPN provider.
func spawnSocks5(vt *wireproxy.VirtualTun) (net.Listener, int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, 0, err
	}

	server := socks5.NewServer(
		socks5.WithDial(vt.Tnet.DialContext),
		socks5.WithResolver(vt),
		socks5.WithAuthMethods([]socks5.Authenticator{socks5.NoAuthAuthenticator{}}),
		socks5.WithBufferPool(bufferpool.NewPool(256*1024)),
	)
	go func() {
		if err := server.Serve(ln); err != nil {
			fmt.Fprintln(os.Stderr, "tvview: socks5 server exited:", err)
		}
	}()

	return ln, ln.Addr().(*net.TCPAddr).Port, nil
}

// Close tears down every tunnel that was ever started and clears the
// WKWebView proxy. Called once, at shutdown.
func (m *vpnManager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()

	for region, rt := range m.started {
		rt.ln.Close()
		rt.vt.Dev.Close()
		delete(m.started, region)
	}
	if m.current != "" {
		if err := webViewProxyClearer(); err != nil {
			fmt.Fprintln(os.Stderr, "tvview: clearing webview proxy on quit:", err)
		}
		m.current = ""
	}
}
