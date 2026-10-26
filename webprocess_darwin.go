//go:build darwin

package main

import (
	"fmt"
	"os"
	"syscall"
	"time"

	"github.com/ebitengine/purego/objc"
)

// A page whose web process wedges (a player stuck in a loop; seen on RaiPlay) never
// answers anything the app sends it: not a navigation, not Cmd-R, not the sidebar.
// Only ending that process helps, and WebKit starts a new one on the next load.
//
// The page tells us it is alive: sidebar.js calls wvPing every few seconds. When the
// pings stop for frozenAfter while the app is in front, the window title says so, and
// the next channel switch, Cmd-R or View > Reset Web View ends the process first.
// The Swift edition does the same with a native bar and a replaced web view.

// frozenAfter is how long a page may go without pinging before it counts as frozen.
// Generous: a page that is merely slow to load has not pinged yet either.
const frozenAfter = 15 * time.Second

// occlusionVisible is NSWindowOcclusionStateVisible.
const occlusionVisible = 1 << 1

var (
	selWebProcessIdentifier = objc.RegisterName("_webProcessIdentifier")
	selRespondsToSelector   = objc.RegisterName("respondsToSelector:")
	selOcclusionState       = objc.RegisterName("occlusionState")
)

// webProcessID is the pid of the web view's web process, through WebKit's
// undocumented _webProcessIdentifier (this app is not an App Store app), or 0.
func (a *app) webProcessID() int {
	view := a.webView()
	if view == 0 || !objc.Send[bool](view, selRespondsToSelector, selWebProcessIdentifier) {
		return 0
	}
	return int(objc.Send[int32](view, selWebProcessIdentifier))
}

// killWebProcess ends the web view's web process. Must be called on the main thread.
func (a *app) killWebProcess() bool {
	pid := a.webProcessID()
	if pid <= 1 {
		return false
	}
	fmt.Fprintln(os.Stderr, "tvview: ending the frozen web process", pid)
	return syscall.Kill(pid, syscall.SIGKILL) == nil
}

// windowVisible reports whether any of the window is on screen. A window that is
// minimised, hidden, or on another Space has its page throttled, which can stop its
// timers: that is not a frozen page. (A visible window that merely lacks focus keeps
// playing, so focus is the wrong test.)
func (a *app) windowVisible() bool {
	window := objc.ID(uintptr(a.w.Window()))
	if window == 0 {
		return true
	}
	return objc.Send[uint](window, selOcclusionState)&occlusionVisible != 0
}

// watch marks the page frozen when its pings stop. Run once, as a goroutine.
func (a *app) watch() {
	for range time.Tick(3 * time.Second) {
		a.w.Dispatch(func() {
			if !a.windowVisible() {
				a.mu.Lock()
				a.lastPing = time.Now()
				a.mu.Unlock()
				return
			}
			a.mu.Lock()
			stale := time.Since(a.lastPing) > frozenAfter && !a.frozen
			if stale {
				a.frozen = true
			}
			cur := a.current
			a.mu.Unlock()
			if stale {
				fmt.Fprintf(os.Stderr, "tvview: the page has not answered for %v\n", frozenAfter)
				a.w.SetTitle(a.windowTitle(cur))
			}
		})
	}
}

// resetWebView ends the web process and loads the current channel again, which is
// View > Reset Web View, and what Cmd-R does while the page is frozen.
func (a *app) resetWebView() {
	a.mu.Lock()
	cur := a.current
	a.frozen = false
	a.lastPing = time.Now()
	a.mu.Unlock()

	a.w.Dispatch(func() {
		a.killWebProcess()
		a.w.SetTitle(a.windowTitle(cur))
		// WebKit notices the process is gone a moment later; a load sent before that
		// goes to the dead process and is lost.
		time.AfterFunc(500*time.Millisecond, func() { a.navigate(cur) })
	})
}
