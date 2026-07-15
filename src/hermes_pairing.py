#!/usr/bin/env python3
"""
Hermes_Pairing — polished dark control app for pairing Hermes + Claude terminals.
"""

from __future__ import annotations

import os
import subprocess
import threading
import time
from pathlib import Path

from AppKit import (
    NSApplication,
    NSApp,
    NSObject,
    NSWindow,
    NSView,
    NSButton,
    NSTextField,
    NSImageView,
    NSMakeRect,
    NSBackingStoreBuffered,
    NSWindowStyleMaskTitled,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskMiniaturizable,
    NSFloatingWindowLevel,
    NSMenu,
    NSMenuItem,
    NSStatusBar,
    NSFont,
    NSImage,
    NSColor,
    NSApplicationActivationPolicyRegular,
    NSLineBreakByWordWrapping,
    NSBezelStyleRounded,
    NSImageScaleProportionallyUpOrDown,
    NSImageAlignCenter,
)
from Foundation import NSMakeSize

SESSION = "hermes-claude"
CLAUDE_WINDOW = "1"
STARTER = Path.home() / "bin" / "start-hermes-claude.sh"
DELEGATE = Path.home() / "bin" / "claude-delegate.py"
LOG = Path.home() / "Library" / "Logs" / "Hermes_Pairing.log"
HERE = Path(__file__).resolve().parent
ICON = HERE / "AppIcon-1024.png"
ILLU = HERE / "pair-illustration.png"
MENU_ICON = HERE / "menubar-template.png"

W, H = 440, 620
PAD = 28


def log(msg: str):
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as f:
            f.write(msg.rstrip() + "\n")
    except Exception:
        pass


def sh(cmd: str) -> str:
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        return (r.stdout or "").strip()
    except Exception as e:
        return str(e)


def notify(title: str, message: str = ""):
    safe_t = title.replace('"', "'")
    safe_m = message.replace('"', "'")[:200]
    sh(f'''osascript -e 'display notification "{safe_m}" with title "{safe_t}"' ''')


def get_sessions():
    out = sh("tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
    return [s for s in out.splitlines() if s.strip()]


def start_fresh():
    project = os.getcwd()
    if STARTER.exists():
        subprocess.Popen(
            ["bash", str(STARTER), project],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    else:
        sh(f"tmux kill-session -t {SESSION} 2>/dev/null || true")
        sh(f"tmux new-session -d -s {SESSION} -n Hermes")
        sh(f"tmux new-window -t {SESSION}:1 -n Claude")
        sh(f"tmux send-keys -t {SESSION}:1 'cd ~ && claude' Enter")
    bring_pair_to_front()
    notify("New pair ready", "Terminal is in front")


def bring_pair_to_front():
    script = f'''
    tell application "Terminal"
        activate
        do script "tmux has-session -t {SESSION} 2>/dev/null && tmux attach -t {SESSION} || echo 'No pair — use New pair'"
        set frontmost to true
    end tell
    tell application "System Events"
        tell process "Terminal"
            set frontmost to true
        end tell
    end tell
    '''
    sh(f"osascript -e {repr(script)}")


def pick_window(prompt: str, label: str):
    notify("Hermes_Pairing", prompt)
    time.sleep(2.0)
    script = '''
    tell application "System Events"
        set mousePos to current position of mouse
        set mouseX to item 1 of mousePos
        set mouseY to item 2 of mousePos
        tell process "Terminal"
            repeat with w in windows
                try
                    set {x, y, wW, wH} to position of w & size of w
                    if mouseX ≥ x and mouseX ≤ (x + wW) and mouseY ≥ y and mouseY ≤ (y + wH) then
                        return id of w as string
                    end if
                end try
            end repeat
        end tell
    end tell
    return "NONE"
    '''
    result = sh(f"osascript -e {repr(script)}")
    if "NONE" in result or not result.isdigit():
        result = sh(
            '''osascript -e 'tell application "Terminal"
            try
                return id of front window as string
            end try
        end tell' '''
        )
    win_id = result.strip()
    if not win_id.isdigit():
        notify("No window", "Hover a Terminal window and try again")
        return None
    sh(
        f'''osascript -e 'tell application "Terminal" to set custom title of window id {win_id} to "● {label}"' '''
    )
    notify(f"{label} selected", "")
    time.sleep(1.0)
    return win_id


def wire(w1, w2):
    sh(
        f'''osascript -e 'tell application "Terminal" to do script "clear; echo HERMES; tmux new-session -d -s {SESSION} 2>/dev/null || true; tmux attach -t {SESSION}" in window id {w1}' '''
    )
    time.sleep(1.2)
    sh(
        f'''osascript -e 'tell application "Terminal" to do script "clear; echo CLAUDE; tmux new-window -t {SESSION}:{CLAUDE_WINDOW} -n Claude 2>/dev/null || true; tmux send-keys -t {SESSION}:{CLAUDE_WINDOW} \\"cd ~ && claude\\" Enter" in window id {w2}' '''
    )
    sh('''osascript -e 'tell application "Terminal" to activate' ''')
    notify("Linked", "Both windows are connected")


def connect_windows():
    w1 = pick_window("Hover the Hermes Terminal for 2s", "HERMES")
    if not w1:
        return
    w2 = pick_window("Hover the Claude Terminal for 2s", "CLAUDE")
    if not w2:
        return
    if w1 == w2:
        notify("Same window", "Pick two different Terminals")
        return
    wire(w1, w2)


def attach_existing():
    sessions = get_sessions()
    if not sessions:
        notify("Nothing to rejoin", "Start a new pair first")
        return
    name = SESSION if SESSION in sessions else sessions[0]
    sh(
        f'''osascript -e 'tell application "Terminal"
        activate
        do script "tmux attach -t {name}"
        set frontmost to true
    end tell' '''
    )
    sh('''osascript -e 'tell application "System Events" to set frontmost of process "Terminal" to true' ''')
    notify("Back in the pair", name)


def lbl(text, frame, bold=False, size=13.0, secondary=False):
    f = NSTextField.labelWithString_(text)
    f.setFont_(
        NSFont.boldSystemFontOfSize_(size) if bold else NSFont.systemFontOfSize_(size)
    )
    if secondary:
        try:
            f.setTextColor_(NSColor.secondaryLabelColor())
        except Exception:
            pass
    f.setFrame_(frame)
    f.setEditable_(False)
    f.setBordered_(False)
    f.setDrawsBackground_(False)
    try:
        f.setLineBreakMode_(NSLineBreakByWordWrapping)
        f.setMaximumNumberOfLines_(3)
    except Exception:
        pass
    return f


def btn(title, action, frame, target):
    b = NSButton.alloc().initWithFrame_(frame)
    b.setTitle_(title)
    b.setBezelStyle_(NSBezelStyleRounded)
    b.setTarget_(target)
    b.setAction_(action)
    return b


class AppDelegate(NSObject):
    statusItem = None
    window = None
    statusLabel = None

    def applicationDidFinishLaunching_(self, notification):
        log("applicationDidFinishLaunching")
        NSApp.setActivationPolicy_(NSApplicationActivationPolicyRegular)

        if ICON.exists():
            img = NSImage.alloc().initWithContentsOfFile_(str(ICON))
            if img:
                img.setSize_(NSMakeSize(128, 128))
                NSApp.setApplicationIconImage_(img)

        window_only = bool(getattr(self, "_window_only", False))
        if not window_only:
            self._build_status_item()
        self._build_window()
        self.refreshStatus_(None)

        NSApp.activateIgnoringOtherApps_(True)
        if self.window:
            self.window.makeKeyAndOrderFront_(None)
        log(f"ready window_only={window_only}")

    def _build_status_item(self):
        bar = NSStatusBar.systemStatusBar()
        # Wider fixed length so Zap always has room
        self.statusItem = bar.statusItemWithLength_(48.0)
        b = self.statusItem.button()
        if b:
            if MENU_ICON.exists():
                timg = NSImage.alloc().initWithContentsOfFile_(str(MENU_ICON))
                if timg:
                    timg.setSize_(NSMakeSize(18, 18))
                    timg.setTemplate_(True)
                    b.setImage_(timg)
            b.setTitle_(" Zap")
            b.setToolTip_("Hermes_Pairing")
            try:
                b.setFont_(NSFont.boldSystemFontOfSize_(13.0))
            except Exception:
                pass
        menu = NSMenu.alloc().init()
        menu.setAutoenablesItems_(False)

        def add(title, action=None):
            if title is None:
                menu.addItem_(NSMenuItem.separatorItem())
                return
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                title, action, ""
            )
            if action:
                item.setTarget_(self)
            menu.addItem_(item)

        add("Show Hermes_Pairing", "showWindow:")
        add(None)
        add("New pair", "startFresh:")
        add("Link two Terminals", "connectWindows:")
        add("Rejoin pair", "attachDefault:")
        add(None)
        add("Quit", "quitApp:")
        self.statusItem.setMenu_(menu)
        try:
            self.statusItem.setHighlightMode_(True)
        except Exception:
            pass

    def _build_window(self):
        style = (
            NSWindowStyleMaskTitled
            | NSWindowStyleMaskClosable
            | NSWindowStyleMaskMiniaturizable
        )
        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, W, H),
            style,
            NSBackingStoreBuffered,
            False,
        )
        self.window.setTitle_("Hermes_Pairing")
        self.window.center()
        self.window.setLevel_(NSFloatingWindowLevel)
        self.window.setReleasedWhenClosed_(False)
        # darker surface
        try:
            self.window.setBackgroundColor_(
                NSColor.colorWithCalibratedRed_green_blue_alpha_(0.09, 0.09, 0.10, 1.0)
            )
        except Exception:
            pass

        content = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, W, H))
        y = H - PAD

        # Header
        y -= 34
        content.addSubview_(
            lbl("Hermes  ↔  Claude", NSMakeRect(PAD, y, W - 2 * PAD, 34), bold=True, size=26)
        )
        y -= 24
        content.addSubview_(
            lbl(
                "Two terminals. One bridge.",
                NSMakeRect(PAD, y, W - 2 * PAD, 20),
                size=14,
                secondary=True,
            )
        )

        # Status
        y -= 32
        self.statusLabel = lbl(
            "○ Idle  ·  no pair running",
            NSMakeRect(PAD, y, W - 2 * PAD, 20),
            size=13,
            secondary=True,
        )
        content.addSubview_(self.statusLabel)

        # Illustration
        y -= 128
        illu = ILLU if ILLU.exists() else Path(
            "/Users/dylandemnard/DigitalBrain/Boreal/tools/hermes-claude-app/resources/pair-illustration.png"
        )
        if illu.exists():
            nsimg = NSImage.alloc().initWithContentsOfFile_(str(illu))
            if nsimg:
                iv = NSImageView.alloc().initWithFrame_(
                    NSMakeRect(PAD, y, W - 2 * PAD, 118)
                )
                iv.setImage_(nsimg)
                iv.setImageScaling_(NSImageScaleProportionallyUpOrDown)
                iv.setImageAlignment_(NSImageAlignCenter)
                content.addSubview_(iv)

        # SETUP
        y -= 36
        content.addSubview_(
            lbl("SETUP", NSMakeRect(PAD, y, W - 2 * PAD, 16), size=11, secondary=True)
        )

        y -= 46
        content.addSubview_(
            btn("New pair", "startFresh:", NSMakeRect(PAD, y, W - 2 * PAD, 40), self)
        )
        y -= 26
        content.addSubview_(
            lbl(
                "Create a fresh Hermes + Claude pair when nothing is running.",
                NSMakeRect(PAD + 2, y, W - 2 * PAD - 4, 22),
                size=12,
                secondary=True,
            )
        )

        y -= 52
        content.addSubview_(
            btn(
                "Link two open Terminals",
                "connectWindows:",
                NSMakeRect(PAD, y, W - 2 * PAD, 40),
                self,
            )
        )
        y -= 26
        content.addSubview_(
            lbl(
                "Wire two Terminal windows you already opened.",
                NSMakeRect(PAD + 2, y, W - 2 * PAD - 4, 22),
                size=12,
                secondary=True,
            )
        )

        # COME BACK
        y -= 40
        content.addSubview_(
            lbl("COME BACK", NSMakeRect(PAD, y, W - 2 * PAD, 16), size=11, secondary=True)
        )

        y -= 46
        content.addSubview_(
            btn(
                "Rejoin pair",
                "attachDefault:",
                NSMakeRect(PAD, y, W - 2 * PAD, 40),
                self,
            )
        )
        y -= 26
        content.addSubview_(
            lbl(
                "Bring the existing pair to the front. Creates nothing new.",
                NSMakeRect(PAD + 2, y, W - 2 * PAD - 4, 22),
                size=12,
                secondary=True,
            )
        )

        # Footer row — clear gap above, no overlap
        footer_y = 28
        half = (W - 2 * PAD - 12) / 2
        content.addSubview_(
            btn(
                "Refresh status",
                "refreshStatus:",
                NSMakeRect(PAD, footer_y, half, 36),
                self,
            )
        )
        content.addSubview_(
            btn(
                "Quit",
                "quitApp:",
                NSMakeRect(PAD + half + 12, footer_y, half, 36),
                self,
            )
        )

        self.window.setContentView_(content)

    def showWindow_(self, sender):
        if self.window:
            NSApp.activateIgnoringOtherApps_(True)
            self.window.makeKeyAndOrderFront_(None)

    def startFresh_(self, sender):
        def work():
            start_fresh()
            time.sleep(0.4)
            self.refreshStatus_(None)

        threading.Thread(target=work, daemon=True).start()

    def connectWindows_(self, sender):
        threading.Thread(target=connect_windows, daemon=True).start()

    def attachDefault_(self, sender):
        def work():
            attach_existing()
            time.sleep(0.3)
            self.refreshStatus_(None)

        threading.Thread(target=work, daemon=True).start()

    def refreshStatus_(self, sender):
        sessions = get_sessions()
        text = (
            f"● Linked  ·  {', '.join(sessions)}"
            if sessions
            else "○ Idle  ·  no pair running"
        )
        if self.statusLabel:
            self.statusLabel.setStringValue_(text)

    def quitApp_(self, sender):
        log("quit")
        NSApp.terminate_(None)

    def applicationShouldHandleReopen_hasVisibleWindows_(self, app, flag):
        self.showWindow_(None)
        return True

    def applicationShouldTerminateAfterLastWindowClosed_(self, sender):
        return False


def main():
    import sys
    window_only = "--window-only" in sys.argv
    log(f"main enter window_only={window_only}")
    app = NSApplication.sharedApplication()
    delegate = AppDelegate.alloc().init()
    # Stash flag for applicationDidFinishLaunching
    delegate._window_only = window_only
    app.setDelegate_(delegate)
    app.setActivationPolicy_(NSApplicationActivationPolicyRegular)
    app.run()


if __name__ == "__main__":
    main()
