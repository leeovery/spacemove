# spacemove

Send the focused window to a macOS Space by number or by its Spaceman label, from Raycast.

- `helper/main.swift`: the `spacemove` CLI. It reads Spaces from the WindowServer and labels from Spaceman (`dev.ruittenb.Spaceman` → `spaceNames`, keyed by ManagedSpaceID), then moves the window.
- `raycast/`: a local Raycast extension with one command:
  - **Move Window to Space**: a list you filter by number or label. ↵ sends the window and follows it. ⌘↵ sends it and you stay where you are; the footer's left slot shows that key.

## Install

On a new Mac, kit does it: kit-config's `spacemove` step (macbook) clones this repository to `~/Code/spacemove` and runs both targets below. To update, `git pull` here and `make install raycast`.

By hand:

```sh
make install         # builds the helper into ~/.local/bin/spacemove
make raycast         # builds the extension into ~/.config/raycast/extensions/spacemove; the first
                     # time, it also imports it into Raycast, which brings Raycast's window up
make raycast-import  # imports it again, as after changing package.json's commands
```

There's no dev server. `ray develop` imports an extension by opening `raycast://cli/<name>/start`, `build-success` and `stop` links, and `scripts/install-raycast` opens the same three around a single `ray build`.

## CLI

```sh
spacemove list                 # * marks the active Space
spacemove move work            # exact name, then prefix, then substring match
spacemove move 4 --follow
spacemove move 4 --method drag # one route only: bridged | direct | compat | drag
spacemove doctor               # private symbols, Accessibility, shortcut per desktop
```

## How the move works

It tries these routes in order and asks the WindowServer after each whether the window landed. Every attempt is logged to `~/Library/Logs/spacemove.log`.

1. **bridged** (macOS 26.4+, the one that works on 26.7): it builds a SkyLight `SLSBridgedMoveWindowsToManagedSpaceOperation` and sends `performWithWMBridgeDelegate`. That hands the operation to SkyLight's window-management bridge (`WMClientWindowManager`), which performs the move. Exported `SLSMoveWindowsToManagedSpace` does the same thing internally, but only when `SLSWindowManagementClientOperationsEnabled()` is true; otherwise it takes the old blocked path. Sending the operation directly skips that check.
2. **direct**: `SLSMoveWindowsToManagedSpace`. Apple blocked this for other apps' windows from macOS 14.5.
3. **compat**: yabai's 14.5 workaround. It tags the target Space with a compat ID and moves the window to that ID.
4. **drag**: runs only with `--method drag`. It holds the title bar and presses "Switch to Desktop N", which moves the pointer and flips the screen.

Without `--follow`, focus goes to the next window on the same display.

`make testwindow` builds `build/testwindow`, which opens a 2×2 transparent window in its own process and prints its window ID. Use it to try routes without touching a real window: `spacemove move id:<space> --window <id> --method bridged`.

## Licence

MIT
