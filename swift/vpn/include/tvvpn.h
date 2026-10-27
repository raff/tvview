#ifndef TVVPN_H
#define TVVPN_H

/// Brings up the WireGuard tunnel for the .conf at `confPath` and returns the
/// port of its local SOCKS5 proxy (127.0.0.1), or -1 with a message in `errBuf`.
/// Blocks while the device comes up: do not call it on the main thread.
int TVVPNStart(const char *confPath, char *errBuf, int errLen);

/// Closes the tunnel started with that port.
void TVVPNStop(int port);

// --- The iOS packet tunnel extension (system VPN) ------------------------------------
// One tunnel per process. Call Prepare before applying the extension's network
// settings, Start after; both return 0, or -1 with a message in errBuf.

/// Parses the WireGuard .conf text and resolves its endpoint.
int TVVPNTunnelPrepare(const char *confText, char *errBuf, int errLen);

/// Finds the utun descriptor the system gave the extension and runs WireGuard on it.
int TVVPNTunnelStart(char *errBuf, int errLen);

void TVVPNTunnelStop(void);

/// Copies the recent log (wireguard-go's and ours) into buf; returns the length.
int TVVPNTunnelLog(char *buf, int len);

#endif
