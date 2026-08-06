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

	// Implemented by our own target class, below.
	selMenuAction      = objc.RegisterName("tvviewMenuAction:")
	selMenuNeedsUpdate = objc.RegisterName("menuNeedsUpdate:")
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
	sidebarItem = addAction(viewMenu, target, "Show Sidebar", `\`, 0, a.toggleSidebar)
	addSeparator(viewMenu)
	addItem(viewMenu, "Enter Full Screen", "toggleFullScreen:", "f", modControl|modCommand)
	viewMenu.Send(selSetDelegate, target)
	addSubmenu(main, "View", viewMenu)

	// Channels. Cmd-1..Cmd-9 for the first nine; the rest are click-only.
	channelsMenu = newMenu("Channels")
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
		},
	)
	if err != nil {
		return 0, fmt.Errorf("registering menu target: %w", err)
	}

	return objc.ID(class).Send(selAlloc).Send(selInit), nil
}

// nsString bridges a Go string to an autoreleased NSString. purego converts
// the string argument to a C string and keeps it alive across the call.
func nsString(s string) objc.ID {
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
