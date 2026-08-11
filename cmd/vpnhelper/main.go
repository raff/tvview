// Command vpnhelper is tvview's privileged half of its VPN tunnels: the only
// part of the app that ever runs as root, and it does exactly one thing.
//
// It creates and configures one real kernel utun(4) interface — the same
// primitive wg-quick uses — then hands the open device file descriptor to
// the unprivileged tvview process that spawned it, over a Unix socket, via
// SCM_RIGHTS. It never touches the system routing table (no default route),
// so nothing outside tvview's own explicitly-bound sockets ever sees this
// interface. Once the fd is sent, the helper exits; tvview drives the
// interface unprivileged from there on, and the interface disappears the
// moment tvview closes that fd.
//
// tvview invokes this via `osascript ... with administrator privileges`, so
// the only prompt the user ever sees is macOS's own admin dialog naming this
// binary — no sudoers configuration, no stored credentials.
package main

import (
	"fmt"
	"net"
	"os"
	"os/exec"

	"golang.org/x/sys/unix"

	"golang.zx2c4.com/wireguard/tun"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "vpnhelper:", err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) < 4 {
		return fmt.Errorf("usage: vpnhelper <unix-socket-path> <mtu> <addr> [addr ...]")
	}
	sockPath := os.Args[1]
	mtu := os.Args[2]
	addrs := os.Args[3:]

	dev, err := tun.CreateTUN("utun", 0) // MTU is set explicitly below, alongside the addresses.
	if err != nil {
		return fmt.Errorf("creating utun device: %w", err)
	}
	name, err := dev.Name()
	if err != nil {
		return fmt.Errorf("naming utun device: %w", err)
	}

	if err := configureInterface(name, mtu, addrs); err != nil {
		return err
	}

	fileDev, ok := dev.(interface{ File() *os.File })
	if !ok {
		return fmt.Errorf("tun device exposes no file descriptor")
	}
	tunFile := fileDev.File()

	return sendFD(sockPath, name, tunFile)
}

// configureInterface assigns addrs (point-to-point: /32 for IPv4, /128 for
// IPv6, matching how every WireGuard client config hands them out) and mtu
// to name, brings it up, and gives it an interface-scoped default route.
//
// That scoped route is the one exception to "never touches the routing
// table": without it, the interface has only its own /32 (or /128) route to
// itself, so a socket bound to it with IP_BOUND_IF can reach nothing at all
// — IP_BOUND_IF restricts which interface's routes a socket may use, it
// doesn't invent one. `-ifscope` is what keeps this from becoming a normal
// system-wide default route: a scoped route is consulted only for sockets
// explicitly bound to this interface (which is exactly what tvview's own
// dialer does — see bindToInterface in vpn_kernel_darwin.go); it's invisible
// to `route get default`, and to every other process and interface on the
// machine, including a concurrently-connected VPN.
func configureInterface(name, mtu string, addrs []string) error {
	var hasV4, hasV6 bool
	for _, a := range addrs {
		ip := net.ParseIP(a)
		if ip == nil {
			return fmt.Errorf("not an IP address: %q", a)
		}

		var args []string
		if ip.To4() != nil {
			args = []string{name, "inet", a, a, "mtu", mtu, "up"}
			hasV4 = true
		} else {
			args = []string{name, "inet6", a, "prefixlen", "128", "mtu", mtu, "up"}
			hasV6 = true
		}

		out, err := exec.Command("/sbin/ifconfig", args...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("ifconfig %s: %w: %s", a, err, out)
		}
	}

	if hasV4 {
		if err := addScopedDefaultRoute(name, "-inet"); err != nil {
			return err
		}
	}
	if hasV6 {
		if err := addScopedDefaultRoute(name, "-inet6"); err != nil {
			return err
		}
	}
	return nil
}

func addScopedDefaultRoute(name, family string) error {
	out, err := exec.Command("/sbin/route", "-q", "-n", "add", family,
		"-ifscope", name, "default", "-interface", name).CombinedOutput()
	if err != nil {
		return fmt.Errorf("scoped route for %s: %w: %s", name, err, out)
	}
	return nil
}

// sendFD hands tunFile's descriptor to whoever is listening on sockPath,
// tagged with the interface name, then closes its own reference. The
// receiver gets its own independent copy of the descriptor — the interface
// stays alive exactly as long as the receiver holds it open.
func sendFD(sockPath, name string, tunFile *os.File) error {
	conn, err := net.Dial("unix", sockPath)
	if err != nil {
		return fmt.Errorf("connecting to tvview: %w", err)
	}
	defer conn.Close()

	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return fmt.Errorf("not a unix socket")
	}

	rights := unix.UnixRights(int(tunFile.Fd()))
	if _, _, err := uc.WriteMsgUnix([]byte(name), rights, nil); err != nil {
		return fmt.Errorf("sending fd: %w", err)
	}
	return nil
}
