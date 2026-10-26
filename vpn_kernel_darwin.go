//go:build darwin

package main

import (
	"net"

	"tvview/internal/kernelvpn"
)

// The kernel-interface tunnel itself (vpnhelper, utun, the interface-bound
// SOCKS5 proxy) lives in internal/kernelvpn, shared with the Swift app's
// library; this is the Go app's view of it.

// regionTunnelKernel is a running tunnel as vpnManager holds it. kt is the real
// thing; tests build one with only ln and port set, since a `go test` run has
// neither the admin prompt nor a WireGuard peer to raise a real one.
type regionTunnelKernel struct {
	kt   *kernelvpn.Tunnel
	ln   net.Listener
	port int
}

// raiseKernelTunnel indirects kernelvpn.Start so tests can substitute a fake.
var raiseKernelTunnel = func(path string) (*regionTunnelKernel, error) {
	kt, err := kernelvpn.Start(path)
	if err != nil {
		return nil, err
	}
	return &regionTunnelKernel{kt: kt, port: kt.Port}, nil
}

func (rt *regionTunnelKernel) Close() {
	if rt.kt != nil {
		rt.kt.Close()
	}
	if rt.ln != nil {
		rt.ln.Close()
	}
}
