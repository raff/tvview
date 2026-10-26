// Package tunnel runs one WireGuard tunnel in-process and exposes it as a local
// SOCKS5 proxy: the Swift app's VPN. Nothing is routed system-wide; only what
// is pointed at the proxy (the web view) goes through the tunnel.
//
// This is the userspace design the Go app used before it moved to a kernel
// interface (see README, "Why a real interface"): it needs no privileges, no
// entitlements and no extension, so it runs on iOS and in the simulator. The
// cost is the one that made the Go app move: some CDNs (BBC iPlayer's asset
// delivery) drop connections whose TCP handshake comes from a userspace stack.
package tunnel

import (
	"fmt"
	"net"
	"sync"

	"github.com/things-go/go-socks5"
	"github.com/things-go/go-socks5/bufferpool"
	"github.com/windtf/wireproxy"
	"golang.zx2c4.com/wireguard/device"
)

// Tunnel is one running WireGuard device and its SOCKS5 listener.
type Tunnel struct {
	vt   *wireproxy.VirtualTun
	ln   net.Listener
	Port int
	once sync.Once
}

// Start brings up the tunnel described by the WireGuard .conf at confPath (the
// bare [Interface]/[Peer] file from the VPN provider, no [Socks5] section
// needed) and returns it listening on a free 127.0.0.1 port.
func Start(confPath string) (*Tunnel, error) {
	conf, err := wireproxy.ParseConfig(confPath)
	if err != nil {
		return nil, fmt.Errorf("parsing %s: %w", confPath, err)
	}

	vt, err := wireproxy.StartWireguard(conf, device.LogLevelError)
	if err != nil {
		return nil, fmt.Errorf("starting wireguard: %w", err)
	}

	// Bound here rather than by wireproxy's own SpawnRoutine, which calls
	// log.Fatal if the listen fails: that would take the whole app down over
	// an unlucky ephemeral-port race.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		vt.Dev.Close()
		return nil, fmt.Errorf("starting socks5 proxy: %w", err)
	}

	server := socks5.NewServer(
		socks5.WithDial(vt.Tnet.DialContext),
		socks5.WithResolver(vt),
		socks5.WithAuthMethods([]socks5.Authenticator{socks5.NoAuthAuthenticator{}}),
		socks5.WithBufferPool(bufferpool.NewPool(256*1024)),
	)
	go server.Serve(ln) // returns when ln is closed

	return &Tunnel{vt: vt, ln: ln, Port: ln.Addr().(*net.TCPAddr).Port}, nil
}

// Close stops the proxy and the WireGuard device. Safe to call twice.
func (t *Tunnel) Close() {
	t.once.Do(func() {
		t.ln.Close()
		t.vt.Dev.Close()
	})
}
