# deskman

English | [日本語](README.ja.md)

A small tool that names macOS desktops (Spaces) and switches to them instantly by name. Names are tied to each desktop's UUID, so they stay correct when desktops are reordered, added or removed.

## Installation

Install with Homebrew. Requires macOS 14 or later on Apple Silicon.

```sh
brew install --cask todayporton/tap/deskman
```

This puts Deskman.app in `/Applications` and the `deskman` command in Homebrew's bin directory.

The app is not signed with a Developer ID or notarized, so Gatekeeper blocks the first launch. To open it:

1. Click "Done" in the dialog saying the app could not be opened.
2. Open System Settings > Privacy & Security and click "Open Anyway" near the bottom.
3. Click "Open Anyway" again in the confirmation dialog and enter your password.

Switching needs Deskman.app running and granted Accessibility access. After launching it, allow Deskman.app in System Settings > Privacy & Security > Accessibility. Choose "ログイン時に起動" (Launch at Login) in its menu to start it automatically. The menu and messages are in Japanese.

`deskman go` asks the running app to switch over a local socket. Only Deskman.app needs the permission; your terminal or Herdr does not.

### Building from source

```sh
bash scripts/bundle.sh
cp -R dist/Deskman.app /Applications/
ln -s /Applications/Deskman.app/Contents/MacOS/deskman ~/.local/bin/deskman
```

By default `scripts/bundle.sh` signs ad hoc, so replacing the app with a new build may require granting the permission again. Signing with your own certificate, as in `CODESIGN_IDENTITY="certificate name" bash scripts/bundle.sh`, lets macOS treat rebuilds as the same app.

## Usage

```
deskman                         Run as a menu bar app
deskman list [--json] [--all]   List desktops (* current, + shown on another display)
deskman current [--json]        Show the current desktop
deskman go [--restore-cursor] [--restore-focus] <name|number|UUID>
                                Switch to a desktop
deskman next [--wrap] [--cursor] [--restore-cursor] [--restore-focus]
                                Switch to the desktop on the right
deskman prev [--wrap] [--cursor] [--restore-cursor] [--restore-focus]
                                Switch to the desktop on the left
deskman rename <target> <name>  Name a desktop ("" removes the name)
deskman rename --forget <name>  Remove a name that is not in the list
```

By default, `next` and `prev` move within the display that has the active window; with `--cursor`, within the display under the cursor. They do not continue onto other displays and fail with exit code 2 at the edge. With `--wrap`, they wrap around to the other end. Full-screen desktops count in their place in the order. Repeated calls advance once per call.

`--restore-cursor` moves the cursor back after a switch that had to move it to another display. `--restore-focus` returns keyboard focus to the previous window if the switch moved it elsewhere. Focus is returned only when the previous window is on screen, and the command finishes without waiting for it. A new switch cancels a pending focus return.

Numbers follow the current order and change when desktops are reordered. Use a name or UUID in calls that must not shift.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Other error |
| 2 | Not found (for `next`/`prev`, already at the edge) |
| 3 | Not in the current list (its display is disconnected, or it was removed) |
| 4 | No Accessibility permission |
| 5 | Could not confirm the switch |
| 6 | Duplicate name |
| 7 | Deskman.app is not running |
| 64 | Invalid arguments |

## Limitations

- Depends on private macOS APIs (`CGSCopyManagedDisplaySpaces` and synthesized Dock swipes), so a macOS update may break it. The event format that changed in macOS 27 is supported, but it has not been tested on macOS 27.
- Desktops with an empty UUID cannot be named.
- Swipes act on the display under the cursor, so when the cursor is on a different display from the target, the cursor moves to the target display by default. `--restore-cursor` moves it back.

## Data

Stored in `~/.config/deskman/`. Delete this folder to remove it.

## Acknowledgements

The swipe synthesis technique is based on [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) (MIT) and [yabai](https://github.com/koekeishiya/yabai) (MIT).

## License

MIT. See `LICENSE`.
