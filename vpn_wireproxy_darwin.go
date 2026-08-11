//go:build darwin

package main

import (
	"fmt"
	"os"
	"sync"
)

// vpnManager owns one WireGuard tunnel per region, each on its own real
// kernel utun(4) interface (vpn_kernel_darwin.go) exposed as a local SOCKS5
// proxy, and points [WKWebsiteDataStore defaultDataStore]
// (vpn_proxy_darwin.go) at whichever one is current. No system routes, no
// wg-quick, and no part of tvview's own long-running process ever runs as
// root — the one privileged operation (raising the interface) lives in the
// short-lived, single-purpose vpnhelper (cmd/vpnhelper), which hands back
// an open device and exits. See README, "Watching from another country".
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
	started map[string]*regionTunnelKernel
	current string
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
	return &vpnManager{tunnels: cfg.Tunnels, started: map[string]*regionTunnelKernel{}}
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
// mu held. The actual work — parsing the .conf, raising a real kernel
// interface for it via vpnhelper, and standing up a local SOCKS5 proxy
// scoped to that interface — lives in vpn_kernel_darwin.go.
func (m *vpnManager) tunnelFor(region string) (*regionTunnelKernel, error) {
	if rt, ok := m.started[region]; ok {
		return rt, nil
	}

	path, ok := m.tunnels[region]
	if !ok {
		return nil, fmt.Errorf("no wireguard config for region %q", region)
	}

	rt, err := raiseKernelTunnel(path)
	if err != nil {
		return nil, fmt.Errorf("starting wireguard for %s: %w", region, err)
	}

	m.started[region] = rt
	return rt, nil
}

// Close tears down every tunnel that was ever started and clears the
// WKWebView proxy. Called once, at shutdown.
func (m *vpnManager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()

	for region, rt := range m.started {
		rt.Close()
		delete(m.started, region)
	}
	if m.current != "" {
		if err := webViewProxyClearer(); err != nil {
			fmt.Fprintln(os.Stderr, "tvview: clearing webview proxy on quit:", err)
		}
		m.current = ""
	}
}
