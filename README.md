# LanguageSwitcher for macOS

A tiny local menu-bar app that fixes text typed in the wrong keyboard layout
(EN ⇄ RU) with a single tap of the **Option (⌥) key**.

- **With a selection** → converts the selection.
- **Without a selection** → converts the word immediately to the left of the caret.
- **Per-app exceptions** — disable the app in Terminal, password managers, etc.
- **Runs at login** (optional).
- **100% local.** No network calls, no analytics, nothing phones home.

## Install (pre-built)

Grab the latest `.dmg` from the
[GitHub Releases](../../releases) page:

1. Open the downloaded `LanguageSwitcher-<version>.dmg`.
2. Drag `LanguageSwitcher.app` into `Applications`.
3. Because the app is self-signed (not notarized), the first launch shows a
   Gatekeeper warning. Right-click the app → **Open** → **Open** in the
   dialog. Or run once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/LanguageSwitcher.app
   ```

4. On first launch, macOS will prompt for **Accessibility** permission.
   Grant it in **System Settings → Privacy & Security → Accessibility**.

## Stack

- Swift 5.9, AppKit + SwiftUI
- `CGEventTap` for the bare Option-tap hotkey
- macOS Accessibility API (`AXUIElement`) to read/replace selected text
- Pasteboard-based fallback for apps that aren't AX-compliant
- `SMAppService` for login-item registration
- macOS 13 (Ventura) or later

## Requirements (to build from source)

- macOS 13+
- Xcode 15+ command-line tools (`xcode-select --install` if missing)

## Build & install from source

```bash
./build.sh            # release build  ->  ./build/LanguageSwitcher.app
./build.sh run        # build and launch
./build.sh install    # build and copy to /Applications
./build.sh debug      # debug build
./build.sh dmg        # build and package ./dist/LanguageSwitcher-<ver>.dmg
```

Alternatively, open `Package.swift` in Xcode directly and run (File → Open… → the
folder). Xcode will understand the Swift package, but you'll still need
`build.sh` to produce the final `.app` bundle.

## First-run setup

1. Launch `LanguageSwitcher.app`. A menu-bar icon with a speech-bubble glyph appears.
2. macOS will ask for **Accessibility** permission. This is required for two
   things:
   - Intercepting the Option key (`CGEventTap`).
   - Reading/replacing text in the focused field (`AXUIElement`).
3. Open **System Settings → Privacy & Security → Accessibility**, find
   `LanguageSwitcher`, and enable the toggle.
4. The app polls every 1.5s for the permission and starts working automatically
   once granted.

> If you move the app between folders after granting permission, you may need to
> remove and re-add it in Accessibility settings (macOS binds permission to the
> app's signed identity + path).

## Usage

Type something in the wrong layout, then:

- Tap and release **Option** alone (don't hold, don't combine with any other key):
  the last word is converted in place.
- Or select a range first, then tap Option: the selection is converted.

The hotkey fires only if Option was tapped **cleanly**:

- If you held Option for longer than 400 ms, it won't fire (you were typing an
  option-modified character).
- If any other key was pressed while Option was down, it won't fire (you were
  using it as a modifier, e.g. `⌥E`).

## Settings

Open via the menu-bar icon → **Settings…**

- **General** — enable/disable, launch at login.
- **Exceptions** — add apps by bundle identifier (picks from `/Applications`).
  LanguageSwitcher is silently skipped when one of these apps is frontmost.
  Seeded by default with Terminal, iTerm2, Keychain Access, and common password
  managers.

## Architecture

```
Sources/LanguageSwitcher/
  App/           @main + AppDelegate (bootstraps permission + status item)
  Hotkey/        CGEventTap state machine for tap-Option detection
  Text/          LayoutConverter, TextReplacer, AXUIElement helpers, key synth
  UI/            NSStatusItem controller, SwiftUI Settings + Onboarding
  Services/      UserDefaults wrapper, SMAppService login item, frontmost app

Resources/
  Info.plist                        LSUIElement=YES (no dock icon)
  LanguageSwitcher.entitlements     no sandbox (required for AX + event tap)

build.sh                            Assembles .app bundle around SPM output
scripts/make-dmg.sh                 Packages the .app into a distributable .dmg
```

High-level flow:

```
Option-tap
  → HotkeyMonitor.onTap()
    → AppDelegate.performConversion()
      → FrontmostApp.bundleId() ∈ blacklist?  → skip
      → TextReplacer:
          AX path:      read AXSelectedText
                        if empty → synth ⌥⇧← → reread
                        write AXSelectedText (converted)
          Fallback:     save pasteboard → synth ⌘C → read →
                        put converted → synth ⌘V → restore pasteboard
```

## Limitations / v1 scope

- Only EN ⇄ RU.
- Hotkey is hardcoded to bare Option-tap (no UI to change it yet).
- No auto-detect while typing (only manual conversion on hotkey). This is
  planned for a future version.
- Ad-hoc / self-signed code signing — fine for personal use. For distribution
  you'll want a Developer ID signature and notarization.

## Troubleshooting

- **Nothing happens on Option-tap.** Make sure Accessibility permission is
  granted. Re-run the app after granting.
- **Conversion produces garbage in some app.** That app likely doesn't expose
  `AXSelectedText` (common in web-based IDEs / custom text widgets). The app
  falls back to the clipboard method, which should still work but is slightly
  less reliable.
- **Option behaves oddly for typing accented characters.** That's not
  LanguageSwitcher — tap-and-release with no other key is what triggers it;
  holding Option to type `ø`, `é`, etc. works as before.
