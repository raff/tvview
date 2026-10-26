#ifndef TVVPN_H
#define TVVPN_H

/// Brings up the WireGuard tunnel for the .conf at `confPath` and returns the
/// port of its local SOCKS5 proxy (127.0.0.1), or -1 with a message in `errBuf`.
/// Blocks while the device comes up: do not call it on the main thread.
int TVVPNStart(const char *confPath, char *errBuf, int errLen);

/// Closes the tunnel started with that port.
void TVVPNStop(int port);

#endif
