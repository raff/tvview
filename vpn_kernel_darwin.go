//go:build darwin

package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/things-go/go-socks5"
	"github.com/windtf/wireproxy"
	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

// vpn_kernel_darwin.go raises a region's WireGuard tunnel on a real kernel
// utun(4) interface instead of wireproxy's userspace netstack — see
// vpn_wireproxy_darwin.go's tunnelFor, which calls startKernelWireguard.
//
// Why this exists at all: some CDN edges (confirmed empirically against the
// BBC iPlayer asset CDN) silently drop connections from gVisor's userspace
// TCP stack while accepting the identical request from the kernel's own TCP
// stack, over the identical WireGuard tunnel and exit IP. A real utun
// interface fixes that because the kernel, not gVisor, ends up generating
// the actual TCP handshake bytes the far end sees — but creating and
// configuring a utun device requires root, which the rest of this app
// deliberately does not run as. vpnhelper (cmd/vpnhelper) is the one
// privileged sliver that does just that, then hands the open device back
// over a Unix socket via SCM_RIGHTS and exits; see its own doc comment for
// the full handoff.
//
// Once we have that interface, tvview's own sockets are pinned to it with
// IP_BOUND_IF/IPV6_BOUND_IF (bindToInterface) rather than by adding a system
// route, which is what keeps this scoped to tvview's own traffic instead of
// system-wide — the same property the netstack backend has, just achieved
// with a real interface instead of a virtual one.

// helperPath finds vpnhelper next to our own executable — bundled into
// Contents/MacOS alongside the main binary by the Makefile.
func helperPath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("locating own executable: %w", err)
	}
	p := filepath.Join(filepath.Dir(exe), "vpnhelper")
	if _, err := os.Stat(p); err != nil {
		return "", fmt.Errorf("vpnhelper not found next to %s: %w", exe, err)
	}
	return p, nil
}

// raiseKernelInterface asks vpnhelper, elevated via a one-time macOS admin
// prompt, to create and configure a real utun device with addrs and mtu. It
// returns the device wrapped for wireguard-go and its kernel interface
// index, without ever having run any of tvview's own code as root.
func raiseKernelInterface(addrs []netip.Addr, mtu int) (tun.Device, int, error) {
	help, err := helperPath()
	if err != nil {
		return nil, 0, err
	}

	sockPath := filepath.Join(os.TempDir(), fmt.Sprintf("tvview-vpn-%d-%s.sock", os.Getpid(), randomToken()))
	os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		return nil, 0, fmt.Errorf("listening for helper: %w", err)
	}
	defer os.Remove(sockPath)
	defer ln.Close()

	args := append([]string{help, sockPath, fmt.Sprint(mtu)}, addrStrings(addrs)...)
	cmd := exec.Command("osascript", "-e", "do shell script "+shellQuoteArgs(args)+" with administrator privileges")
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, 0, fmt.Errorf("starting vpnhelper: %w", err)
	}

	// Generous: this deadline covers however long the user takes to notice
	// and answer macOS's admin-password dialog, not just vpnhelper's own
	// (near-instant) work once authorized.
	if err := ln.(*net.UnixListener).SetDeadline(time.Now().Add(5 * time.Minute)); err != nil {
		return nil, 0, err
	}
	fdConn, err := ln.Accept()
	if err != nil {
		return nil, 0, fmt.Errorf("waiting for vpnhelper: %w", err)
	}
	uc := fdConn.(*net.UnixConn)
	defer uc.Close()

	nameBuf := make([]byte, 64)
	oob := make([]byte, 64)
	n, oobn, _, _, err := uc.ReadMsgUnix(nameBuf, oob)
	if err != nil {
		return nil, 0, fmt.Errorf("reading interface from vpnhelper: %w", err)
	}
	name := string(nameBuf[:n])

	scms, err := unix.ParseSocketControlMessage(oob[:oobn])
	if err != nil || len(scms) == 0 {
		return nil, 0, fmt.Errorf("no descriptor from vpnhelper: %w", err)
	}
	fds, err := unix.ParseUnixRights(&scms[0])
	if err != nil || len(fds) == 0 {
		return nil, 0, fmt.Errorf("no descriptor from vpnhelper: %w", err)
	}

	// vpnhelper has handed off the fd and is exiting; nothing further of
	// tvview's ever ran privileged.
	_ = cmd.Wait()

	tunFile := os.NewFile(uintptr(fds[0]), name)
	tunDev, err := tun.CreateTUNFromFile(tunFile, 0) // address+MTU already set by vpnhelper
	if err != nil {
		return nil, 0, fmt.Errorf("wrapping interface from vpnhelper: %w", err)
	}

	iface, err := net.InterfaceByName(name)
	if err != nil {
		tunDev.Close()
		return nil, 0, fmt.Errorf("looking up %s: %w", name, err)
	}

	return tunDev, iface.Index, nil
}

func addrStrings(addrs []netip.Addr) []string {
	out := make([]string, len(addrs))
	for i, a := range addrs {
		out[i] = a.String()
	}
	return out
}

// randomToken makes the helper socket path unpredictable; it sits in a
// world-readable temp directory only for the few seconds a tunnel takes to
// raise.
func randomToken() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// shellQuoteArgs renders args as a single-quoted, space-joined string safe
// to splice into an AppleScript `do shell script "..."` command. Every
// argument here is either our own executable path or a value tvview itself
// parsed from a local wireguard .conf (never user-typed free text at
// runtime), but this is cheap insurance regardless.
func shellQuoteArgs(args []string) string {
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = "'" + strings.ReplaceAll(a, "'", `'\''`) + "'"
	}
	// The whole thing is itself one AppleScript string literal.
	return `"` + strings.ReplaceAll(strings.Join(quoted, " "), `"`, `\"`) + `"`
}

// bindToInterface returns a net.Dialer.Control that pins every socket it
// opens to ifIndex via IP_BOUND_IF/IPV6_BOUND_IF, instead of letting the
// kernel's normal routing table pick an interface. This is what scopes
// tvview's own connections to the tunnel without adding any system route —
// nothing else on the machine, including a concurrently-connected VPN, is
// affected.
func bindToInterface(ifIndex int) func(network, address string, c syscall.RawConn) error {
	return func(network, address string, c syscall.RawConn) error {
		var sockErr error
		err := c.Control(func(fd uintptr) {
			switch {
			case strings.Contains(network, "6"):
				sockErr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, ifIndex)
			default:
				sockErr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, ifIndex)
			}
		})
		if err != nil {
			return err
		}
		return sockErr
	}
}

// tunnelResolver answers SOCKS5 hostname lookups by querying the WireGuard
// tunnel's own DNS server (from the .conf's DNS= line) over a socket bound
// to the tunnel interface — the system resolver has no route to it, since
// it's only reachable through the tunnel.
type tunnelResolver struct {
	resolver *net.Resolver
}

func newTunnelResolver(ifIndex int, dnsServers []netip.Addr) (*tunnelResolver, error) {
	if len(dnsServers) == 0 {
		return nil, fmt.Errorf("wireguard config has no DNS server to resolve through")
	}
	server := net.JoinHostPort(dnsServers[0].String(), "53")
	dial := bindToInterface(ifIndex)

	return &tunnelResolver{resolver: &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			d := &net.Dialer{Control: dial}
			return d.DialContext(ctx, network, server)
		},
	}}, nil
}

// Resolve implements socks5.NameResolver.
func (r *tunnelResolver) Resolve(ctx context.Context, name string) (context.Context, net.IP, error) {
	ips, err := r.resolver.LookupIP(ctx, "ip", name)
	if err != nil {
		return ctx, nil, err
	}
	return ctx, ips[0], nil
}

// regionTunnelKernel is a WireGuard tunnel raised on a real kernel utun
// device, exposed as a local SOCKS5 proxy exactly like regionTunnel is for
// the netstack backend — see vpn_wireproxy_darwin.go.
type regionTunnelKernel struct {
	dev *device.Device
	tun tun.Device
	ln  net.Listener
	port int
}

// raiseKernelTunnel indirects startKernelWireguard so tests can substitute a
// fake: the real path needs an admin-privilege prompt and a real network
// path to a WireGuard peer, neither of which a `go test` run can provide.
var raiseKernelTunnel = startKernelWireguard

// startKernelWireguard parses path, raises a real kernel interface for it
// via vpnhelper, and brings up a WireGuard device against that interface.
// Config parsing and the wire-format IPC request are wireproxy's own code
// (ParseConfig/CreateIPCRequest) — only the interface underneath differs
// from wireproxy.StartWireguard, which always uses its own netstack.
func startKernelWireguard(path string) (*regionTunnelKernel, error) {
	conf, err := wireproxy.ParseConfig(path)
	if err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	setting, err := wireproxy.CreateIPCRequest(conf.Device)
	if err != nil {
		return nil, err
	}

	kernTun, ifIndex, err := raiseKernelInterface(setting.DeviceAddr, setting.MTU)
	if err != nil {
		return nil, fmt.Errorf("raising kernel interface: %w", err)
	}

	dev := device.NewDevice(kernTun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, ""))
	if err := dev.IpcSet(setting.IpcRequest); err != nil {
		dev.Close()
		return nil, fmt.Errorf("configuring wireguard device: %w", err)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, fmt.Errorf("bringing wireguard device up: %w", err)
	}

	resolver, err := newTunnelResolver(ifIndex, setting.DNS)
	if err != nil {
		dev.Close()
		return nil, err
	}

	ln, port, err := spawnSocks5Kernel(ifIndex, resolver)
	if err != nil {
		dev.Close()
		return nil, fmt.Errorf("starting socks5 proxy: %w", err)
	}

	return &regionTunnelKernel{dev: dev, tun: kernTun, ln: ln, port: port}, nil
}

// spawnSocks5Kernel mirrors spawnSocks5 in vpn_wireproxy_darwin.go, but
// dials out through a real kernel socket pinned to the tunnel interface
// (bindToInterface) instead of wireproxy's netstack Tnet.
func spawnSocks5Kernel(ifIndex int, resolver socks5.NameResolver) (net.Listener, int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, 0, err
	}

	dialer := &net.Dialer{Control: bindToInterface(ifIndex)}
	server := socks5.NewServer(
		socks5.WithDial(dialer.DialContext),
		socks5.WithResolver(resolver),
		socks5.WithAuthMethods([]socks5.Authenticator{socks5.NoAuthAuthenticator{}}),
	)
	go func() {
		if err := server.Serve(ln); err != nil {
			fmt.Fprintln(os.Stderr, "tvview: kernel-tunnel socks5 server exited:", err)
		}
	}()

	return ln, ln.Addr().(*net.TCPAddr).Port, nil
}

func (rt *regionTunnelKernel) Close() {
	rt.ln.Close()
	// dev is nil for the fake tunnels vpn_test.go substitutes via
	// raiseKernelTunnel, which can't stand up a real WireGuard device.
	if rt.dev != nil {
		rt.dev.Close()
	}
}
