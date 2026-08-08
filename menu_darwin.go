//go:build darwin

package main

import (
	"fmt"

	"github.com/ebitengine/purego/objc"
)

// NSEventModifierFlags. A key equivalent already implies Command, so only the
// extra modifiers ever need spelling out.
const (
	modShift   = 1 << 17
	modControl = 1 << 18
	modOption  = 1 << 19
	modCommand = 1 << 20
)

// NSControlStateValue
const (
	stateOff = 0
	stateOn  = 1
)

// Selectors are safe to resolve at init: purego/objc loads libobjc itself.
// Classes are not — see installMenuBar.
var (
	selAlloc              = objc.RegisterName("alloc")
	selInit               = objc.RegisterName("init")
	selSharedApplication  = objc.RegisterName("sharedApplication")
	selStringWithUTF8     = objc.RegisterName("stringWithUTF8String:")
	selInitWithTitle      = objc.RegisterName("initWithTitle:")
	selInitTitleActionKey = objc.RegisterName("initWithTitle:action:keyEquivalent:")
	selSeparatorItem      = objc.RegisterName("separatorItem")
	selAddItem            = objc.RegisterName("addItem:")
	selSetSubmenu         = objc.RegisterName("setSubmenu:")
	selSetModifierMask    = objc.RegisterName("setKeyEquivalentModifierMask:")
	selSetMainMenu        = objc.RegisterName("setMainMenu:")
	selSetWindowsMenu     = objc.RegisterName("setWindowsMenu:")
	selSetTarget          = objc.RegisterName("setTarget:")
	selSetTag             = objc.RegisterName("setTag:")
	selTag                = objc.RegisterName("tag")
	selSetTitle           = objc.RegisterName("setTitle:")
	selSetState           = objc.RegisterName("setState:")
	selSetDelegate        = objc.RegisterName("setDelegate:")

	selReload        = objc.RegisterName("reload")
	selSubviews      = objc.RegisterName("subviews")
	selCount         = objc.RegisterName("count")
	selObjectAtIndex = objc.RegisterName("objectAtIndex:")
	selIsKindOfClass = objc.RegisterName("isKindOfClass:")
	selWindows       = objc.RegisterName("windows")

	selAddObserver = objc.RegisterName("addObserver:selector:name:object:")
	selDefaultCtr  = objc.RegisterName("defaultCenter")

	// Implemented by our own target class, below.
	selMenuAction      = objc.RegisterName("tvviewMenuAction:")
	selMenuNeedsUpdate = objc.RegisterName("menuNeedsUpdate:")
	selWindowWillClose = objc.RegisterName("tvviewWindowWillClose:")
)

// AppKit classes, resolved by installMenuBar rather than at init. See there.
var (
	classApplication objc.Class
	classMenu        objc.Class
	classMenuItem    objc.Class
	classString      objc.Class
)

// Menu state that the action and update callbacks need. These live for the
// process, like the menus themselves; there is only ever one menu bar.
var (
	menuApp *app

	// menuActions is indexed by an NSMenuItem's tag. Tags start at 1 because 0
	// is what an item carries when nobody sets one.
	menuActions []func()

	sidebarItem  objc.ID
	viewMenu     objc.ID
	channelsMenu objc.ID
	channelItems []objc.ID // parallel to menuApp.cfg.Channels
)

// menuAction is the IMP behind every item we implement ourselves. Items are
// distinguished by tag rather than by a selector each, which keeps one
// registered method serving the whole menu bar however long the channel list
// gets.
//
// AppKit calls this on the main thread.
func menuAction(_ objc.ID, _ objc.SEL, sender objc.ID) {
	tag := objc.Send[int](sender, selTag)
	if tag < 1 || tag > len(menuActions) {
		return
	}
	menuActions[tag-1]()
}

// menuNeedsUpdate refreshes titles and checkmarks just before a menu opens.
// Doing it here rather than pushing on every state change means the menu
// cannot drift out of step with the page, and costs nothing while closed.
func menuNeedsUpdate(_ objc.ID, _ objc.SEL, menu objc.ID) {
	if menuApp == nil {
		return
	}

	menuApp.mu.Lock()
	open, current := menuApp.open, menuApp.current
	menuApp.mu.Unlock()

	switch menu {
	case viewMenu:
		title := "Show Sidebar"
		if open {
			title = "Hide Sidebar"
		}
		sidebarItem.Send(selSetTitle, nsString(title))

	case channelsMenu:
		for i, item := range channelItems {
			state := stateOff
			if menuApp.cfg.Channels[i].URL == current {
				state = stateOn
			}
			item.Send(selSetState, state)
		}
	}
}

// windowWillClose is the notification-based counterpart to requestQuit, for
// the one quit path that never calls it: the window's own red close button,
// handled entirely inside libwebview. See the observer registration in
// installMenuBar for why a notification and not a delegate.
//
// AppKit calls this on the main thread, synchronously, as part of closing the
// window — so a.shutdown() blocking here genuinely holds up the close (and
// libwebview's own subsequent decision to quit the app) for as long as it
// runs, the same way it holds up requestQuit's callers.
func windowWillClose(_ objc.ID, _ objc.SEL, _ objc.ID) {
	if menuApp != nil {
		menuApp.shutdown()
	}
}

// installMenuBar builds the application's main menu and installs it.
//
// The embedded libwebview never creates one — the dylib contains no NSMenu
// symbols at all — and on macOS every keyboard shortcut *is* a menu item's key
// equivalent. AppKit dispatches those from NSApp.mainMenu inside sendEvent:,
// before the event reaches web content, which is why these work even when
// focus sits inside a player iframe and sidebar.js has stopped hearing keys.
//
// Must be called on the main thread, after webview.New and before Run. The
// ordering is not just about NSApplication existing: AppKit is not linked into
// this binary at all, and only enters the process when go-webview dlopens
// libwebview with RTLD_GLOBAL. Resolve these classes any earlier and every one
// of them is nil — whereupon objc_msgSend to a nil class quietly returns nil
// and the whole menu silently fails to appear.
//
// Nothing here is ever released. The menus live for the life of the process,
// and purego gives us no ARC to do it for us.
func installMenuBar(a *app) error {
	menuApp = a
	appName := a.cfg.Window.Title

	classApplication = objc.GetClass("NSApplication")
	classMenu = objc.GetClass("NSMenu")
	classMenuItem = objc.GetClass("NSMenuItem")
	classString = objc.GetClass("NSString")

	for name, c := range map[string]objc.Class{
		"NSApplication": classApplication,
		"NSMenu":        classMenu,
		"NSMenuItem":    classMenuItem,
		"NSString":      classString,
	} {
		if c == 0 {
			return fmt.Errorf("AppKit class %s not found: is the webview loaded yet?", name)
		}
	}

	target, err := newMenuTarget()
	if err != nil {
		return err
	}

	// The red close button never reaches requestQuit: libwebview owns the
	// window and its own delegate answers applicationShouldTerminateAfterLast-
	// WindowClosed: entirely inside the native library, with no call back into
	// this process's Go code. NSWindowWillCloseNotification is the fix rather
	// than fighting over the delegate — it is a notification, not a
	// one-object-only role, so any number of observers can watch it alongside
	// whatever libwebview already is, and object: scopes it to this one window
	// so the quit-prompt HUD's own window (see quit_darwin.go) cannot trigger
	// it. There is exactly one real window for the app's whole life —
	// fullscreen swaps views inside it rather than swapping windows (see
	// fullscreen_darwin.go) — so "this window closing" and "the app quitting"
	// are the same event here.
	if window := objc.ID(uintptr(a.w.Window())); window != 0 {
		if classCenter := objc.GetClass("NSNotificationCenter"); classCenter != 0 {
			center := objc.ID(classCenter).Send(selDefaultCtr)
			center.Send(selAddObserver, target, selWindowWillClose,
				nsString("NSWindowWillCloseNotification"), window)
		}
	}

	app := objc.ID(classApplication).Send(selSharedApplication)
	main := newMenu("")

	// The application menu. AppKit takes its displayed title from the process
	// name whatever we pass, but the item titles below are ours.
	appMenu := newMenu(appName)
	addItem(appMenu, "About "+appName, "orderFrontStandardAboutPanel:", "", 0)
	addSeparator(appMenu)
	addItem(appMenu, "Hide "+appName, "hide:", "h", 0)
	addItem(appMenu, "Hide Others", "hideOtherApplications:", "h", modOption|modCommand)
	addItem(appMenu, "Show All", "unhideAllApplications:", "", 0)
	addSeparator(appMenu)
	// Not terminate:. See requestQuit — the menu quits at once, Cmd-Q asks.
	addAction(appMenu, target, "Quit "+appName, "q", 0, a.requestQuit)
	addSubmenu(main, appName, appMenu)

	// Edit. These actions are not implemented by us: with a nil target AppKit
	// walks the responder chain, where WKWebView picks them up. That is what
	// restores copy and paste inside pages.
	editMenu := newMenu("Edit")
	addItem(editMenu, "Undo", "undo:", "z", 0)
	addItem(editMenu, "Redo", "redo:", "z", modShift|modCommand)
	addSeparator(editMenu)
	addItem(editMenu, "Cut", "cut:", "x", 0)
	addItem(editMenu, "Copy", "copy:", "c", 0)
	addItem(editMenu, "Paste", "paste:", "v", 0)
	addItem(editMenu, "Select All", "selectAll:", "a", 0)
	addSubmenu(main, "Edit", editMenu)

	// View. The sidebar item is the whole point of the exercise: F9 dies inside
	// a cross-origin player, Cmd-\ does not. toggleFullScreen: is NSWindow's,
	// reached down the responder chain — the window's fullscreen, not the
	// player's.
	viewMenu = newMenu("View")
	addAction(viewMenu, target, "Reload", "r", 0, a.reload)
	addSeparator(viewMenu)
	sidebarItem = addAction(viewMenu, target, "Show Sidebar", `\`, 0, a.toggleSidebar)
	addSeparator(viewMenu)
	addItem(viewMenu, "Enter Full Screen", "toggleFullScreen:", "f", modControl|modCommand)
	viewMenu.Send(selSetDelegate, target)
	addSubmenu(main, "View", viewMenu)

	// Channels. Cmd-1..Cmd-9 for the first nine; the rest are click-only.
	channelsMenu = newMenu("Channels")
	addAction(channelsMenu, target, "Channel Up", "]", 0, func() { a.stepChannel(1) })
	addAction(channelsMenu, target, "Channel Down", "[", 0, func() { a.stepChannel(-1) })
	addSeparator(channelsMenu)
	channelItems = make([]objc.ID, 0, len(a.cfg.Channels))
	for i, c := range a.cfg.Channels {
		key := ""
		if i < 9 {
			key = string(rune('1' + i))
		}
		url := c.URL // not the loop variable, for the closure
		item := addAction(channelsMenu, target, c.Title, key, 0, func() {
			a.selectChannel(url)
		})
		channelItems = append(channelItems, item)
	}
	channelsMenu.Send(selSetDelegate, target)
	addSubmenu(main, "Channels", channelsMenu)

	windowMenu := newMenu("Window")
	addItem(windowMenu, "Minimize", "performMiniaturize:", "m", 0)
	addItem(windowMenu, "Zoom", "performZoom:", "", 0)
	addSeparator(windowMenu)
	addItem(windowMenu, "Close", "performClose:", "w", 0)
	addSubmenu(main, "Window", windowMenu)

	app.Send(selSetMainMenu, main)
	app.Send(selSetWindowsMenu, windowMenu)
	return nil
}

// reload reloads whatever page is on screen, in place.
//
// This is WKWebView's own -reload, not a re-navigation to the channel's URL:
// Cmd-R is for unsticking a player mid-show, and re-navigating would throw away
// wherever you had got to inside the site. Being native, it also does not care
// whether the page's own JavaScript is still running — which, when the player
// has wedged, it very often is not.
//
// The item is wired to this rather than to WKWebView's reload: down the
// responder chain. That chain starts at the first responder, so before anything
// in the page has been clicked it runs window → delegate → NSApp and never
// reaches the web view at all, leaving the item greyed out. Messaging the view
// directly works whatever holds focus.
//
// If the view cannot be found the page is asked to reload itself, which is the
// best that can be done without anything native to message.
func (a *app) reload() {
	a.w.Dispatch(func() {
		if view := a.webView(); view != 0 {
			view.Send(selReload)
			return
		}

		// Deliberately not a.Navigate(a.current): a.current is the channel's
		// *configured* URL, never wherever you had browsed to, so going there
		// drops you on the channel's home page. That was the Cmd-R bug — in
		// player fullscreen the view was invisible to webView() and every
		// reload took this branch.
		a.w.Eval("location.reload();")
	})
}

// cachedWebView is the WKWebView once found. Its identity never changes for the
// life of the process and it is retained by whatever window it currently sits
// in, so a bare pointer stays good — including across the reparenting below.
var cachedWebView objc.ID

// webView finds the WKWebView, or 0. go-webview makes it the window's content
// view, but that is its business and not a promise, so this searches the view
// tree rather than assuming a depth.
//
// It looks beyond our own window because WebKit moves the web view into a
// window of its own for element fullscreen — the player's fullscreen button,
// not the View menu's. While that is up, our window's content view no longer
// contains it, and a search that stopped there would come back empty at exactly
// the moment Cmd-R is most wanted.
func (a *app) webView() objc.ID {
	if cachedWebView != 0 {
		return cachedWebView
	}

	classWebView := objc.GetClass("WKWebView")
	if classWebView == 0 {
		return 0
	}

	var find func(view objc.ID) objc.ID
	find = func(view objc.ID) objc.ID {
		if view == 0 {
			return 0
		}
		if objc.Send[bool](view, selIsKindOfClass, objc.ID(classWebView)) {
			return view
		}

		subviews := view.Send(selSubviews)
		for i, n := 0, objc.Send[int](subviews, selCount); i < n; i++ {
			if found := find(subviews.Send(selObjectAtIndex, i)); found != 0 {
				return found
			}
		}
		return 0
	}

	// Our own window first — the usual case, and the cheapest.
	if window := objc.ID(uintptr(a.w.Window())); window != 0 {
		if view := find(window.Send(selContentView)); view != 0 {
			cachedWebView = view
			return view
		}
	}

	// Then every window the application has, which is where a fullscreen host
	// window shows up. Resolved here rather than trusting installMenuBar to
	// have run: this is reachable from anywhere.
	classApp := classApplication
	if classApp == 0 {
		classApp = objc.GetClass("NSApplication")
	}
	if classApp == 0 {
		return 0
	}

	windows := objc.ID(classApp).Send(selSharedApplication).Send(selWindows)
	for i, n := 0, objc.Send[int](windows, selCount); i < n; i++ {
		window := windows.Send(selObjectAtIndex, i)
		if view := find(window.Send(selContentView)); view != 0 {
			cachedWebView = view
			return view
		}
	}

	return 0
}

// newMenuTarget registers the class that receives our own menu items' clicks
// and acts as menu delegate, and returns the single shared instance.
//
// The standard selectors used elsewhere need no target at all. These items
// have no AppKit equivalent, so something has to exist on the ObjC side to be
// messaged — hence a real class, built at runtime.
func newMenuTarget() (objc.ID, error) {
	class, err := objc.RegisterClass(
		"TVViewMenuTarget",
		objc.GetClass("NSObject"),
		nil,
		nil,
		[]objc.MethodDef{
			{Cmd: selMenuAction, Fn: menuAction},
			{Cmd: selMenuNeedsUpdate, Fn: menuNeedsUpdate},
			{Cmd: selWindowWillClose, Fn: windowWillClose},
		},
	)
	if err != nil {
		return 0, fmt.Errorf("registering menu target: %w", err)
	}

	return objc.ID(class).Send(selAlloc).Send(selInit), nil
}

// nsString bridges a Go string to an autoreleased NSString. purego converts
// the string argument to a C string and keeps it alive across the call.
//
// It resolves NSString itself if installMenuBar has not run yet, so callers
// outside the menu bar do not have to care about that ordering. Still no good
// before the webview is created — that is what brings AppKit into the process.
func nsString(s string) objc.ID {
	if classString == 0 {
		classString = objc.GetClass("NSString")
	}
	return objc.ID(classString).Send(selStringWithUTF8, s)
}

func newMenu(title string) objc.ID {
	return objc.ID(classMenu).Send(selAlloc).Send(selInitWithTitle, nsString(title))
}

// addItem appends an item. An empty action leaves the item inert; a zero mask
// keeps AppKit's default of Command alone.
func addItem(menu objc.ID, title, action, key string, mask uint) objc.ID {
	var sel objc.SEL
	if action != "" {
		sel = objc.RegisterName(action)
	}

	item := objc.ID(classMenuItem).Send(selAlloc).
		Send(selInitTitleActionKey, nsString(title), sel, nsString(key))
	if mask != 0 {
		item.Send(selSetModifierMask, mask)
	}

	menu.Send(selAddItem, item)
	return item
}

// addAction appends an item handled by Go. The tag is the index back into
// menuActions; see menuAction.
func addAction(menu, target objc.ID, title, key string, mask uint, fn func()) objc.ID {
	item := addItem(menu, title, "tvviewMenuAction:", key, mask)
	item.Send(selSetTarget, target)

	menuActions = append(menuActions, fn)
	item.Send(selSetTag, len(menuActions))
	return item
}

func addSeparator(menu objc.ID) {
	menu.Send(selAddItem, objc.ID(classMenuItem).Send(selSeparatorItem))
}

// addSubmenu hangs a submenu off the menu bar. The bar's own items carry no
// action of their own, only the submenu.
func addSubmenu(main objc.ID, title string, sub objc.ID) {
	item := addItem(main, title, "", "", 0)
	item.Send(selSetSubmenu, sub)
}
