// tvvpncheck brings a tunnel up from a WireGuard .conf and fetches a URL
// through it, to see what the exit looks like without involving the app:
//
//	go run ./swift/vpn/cmd/tvvpncheck path/to/UK.conf [url]
//
// The default URL reports the exit address and country.
package main

import (
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"time"

	"tvview/swift/vpn/tunnel"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: tvvpncheck file.conf [url]")
		os.Exit(2)
	}
	target := "https://ipinfo.io/json"
	if len(os.Args) > 2 {
		target = os.Args[2]
	}

	start := time.Now()
	t, err := tunnel.Start(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "start:", err)
		os.Exit(1)
	}
	defer t.Close()
	fmt.Printf("tunnel up in %v, socks5 on 127.0.0.1:%d\n", time.Since(start).Round(time.Millisecond), t.Port)

	proxy, _ := url.Parse(fmt.Sprintf("socks5://127.0.0.1:%d", t.Port))
	client := &http.Client{
		Timeout:   25 * time.Second,
		Transport: &http.Transport{Proxy: http.ProxyURL(proxy)},
	}
	start = time.Now()
	resp, err := client.Get(target)
	if err != nil {
		fmt.Fprintln(os.Stderr, "get:", err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
	fmt.Printf("%s -> %s in %v\n%s\n", target, resp.Status, time.Since(start).Round(time.Millisecond), body)
}
