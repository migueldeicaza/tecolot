<p align="center">
  <img src="website/public/assets/owl.png" alt="Tecolot owl" width="180">
</p>

<h1 align="center">Tecolot</h1>

<p align="center">
  A high-performance native terminal for macOS, built with SwiftTerm,
  CoreText, and Metal.
</p>

<p align="center">
  <a href="https://tecolot.com/">Website</a>
  · <a href="https://github.com/migueldeicaza/tecolot/releases/latest">Download</a>
  · <a href="https://tecolot.com/#docs">Getting started</a>
  · <a href="https://tecolot.com/#features">Features</a>
  · <a href="https://github.com/migueldeicaza/tecolot/issues">Issues</a>
  · <a href="https://discord.com/invite/rgN3yzHg8G">Discord</a>
</p>

Tecolot combines a high-throughput terminal engine with native macOS behavior
and modern terminal protocols. You get native windows, tabs, menus, panels,
and automation. You also get Unicode text, modern keyboard input, inline
graphics, and automatic shell integration.

The application uses SwiftUI and AppKit around the
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) terminal engine. It is
designed for people who want a capable terminal that looks and works like a
Mac application.

## Why Tecolot

- **Native macOS workflow.** Use native tabs, split panes, Quick Look, Find,
  Print, the system font panel, Secure Keyboard Entry, AppleScript, and App
  Shortcuts.
- **High-throughput terminal core.** In local `vtebench` tests, Tecolot needed
  15% less combined mean time than a released Ghostty build across 10 shared
  workloads. A newer Ghostty development build was 26% ahead of Tecolot.
- **Visual configuration.** Create profiles in Settings. Configure the shell,
  working directory, environment, font, colors, cursor, opacity, key mappings,
  scrollback, and window behavior without a configuration language.
- **Theme exploration.** Search 141 built-in themes. Browse them in a grid or
  on a visual color map, sort them by color and contrast, and preview them
  before you apply them.
- **Modern terminal support.** Use TrueColor, bidirectional text, the Kitty
  keyboard protocol, mouse reporting, semantic prompts, hyperlinks, and Sixel,
  iTerm2, or Kitty graphics.
- **Restorable workspaces.** Save terminal sessions as documents. Save named
  window groups with their positions, tabs, profiles, working directories, and
  theme overrides.

## Performance

Tecolot uses SwiftTerm's optimized terminal engine and a dedicated render loop
that combines pending screen updates. Metal draws the terminal by default.
This design keeps high-volume output fast without making the interface
unresponsive.

The following results come from local
[`vtebench`](https://github.com/alacritty/vtebench) tests that used the same Mac
and workload set.
[Ghostty](https://ghostty.org/docs/about#fast) is a useful reference because it
also targets the high-performance terminal class. It is a demanding baseline,
not an average terminal.

| Build | Measurement date | Sum of 10 mean write times |
| --- | --- | ---: |
| Ghostty release build | 2026-08-11 | 199.53 ms |
| **Tecolot / SwiftTerm test build** | **2026-09-14** | **168.97 ms** |
| Ghostty development build | 2026-08-31 | 124.88 ms |

Lower values are better. The Tecolot run had a lower mean time in 8 of the 10
workloads than the Ghostty release build. It processed the dense styled-cell
workload at 145.6 MiB/s and the Unicode workload at 263.7 MiB/s. The newer
Ghostty development build still leads the combined suite, but Tecolot is in
the same performance range.

Each workload ran for three seconds and processed at least 1 MiB per sample.
The total is the sum of the mean sample times for cell, Unicode, synchronized
output, and scrolling workloads. Suite totals repeat to about 1%. Individual
tests usually repeat to about 3%, and some repeat to about 7%. Treat small
differences as ties.

These tests measure PTY write and terminal processing throughput. They do not
measure application startup, complete frame latency, or power use.

## Highlights

### Windows, tabs, and panes

- Open multiple native windows and tabs.
- Split a terminal vertically or horizontally.
- Move between panes by order or direction.
- Resize a split by one terminal cell, equalize panes, or zoom one pane.
- Restore window size and position after you restart the application.
- Save and reopen named groups of windows and tabs.

### Profiles and appearance

- Create, duplicate, rename, import, export, and apply profiles.
- Run the login shell or a custom command.
- Set profile-specific environment variables and terminal identity values.
- Configure fonts, cursors, opacity, window titles, scrollback, exit behavior,
  and key mappings.
- Import JSON themes and iTerm2 `.itermcolors` files.
- Edit a copy of any supplied theme.
- Use the built-in Nerd Font Symbols fallback when your selected font does not
  contain a required symbol.

### Text, input, and terminal protocols

- Emulate common VT100 and Xterm behavior, including ANSI and VT500 escape
  sequences.
- Render emoji, combining characters, grapheme clusters, and bidirectional
  Arabic and Hebrew text.
- Use Unicode 17 character-width data, 256 colors, and 24-bit color.
- Use the Kitty keyboard protocol and X10, SGR, UTF-8, or URxvt mouse reports.
- Display Sixel images and images that use the iTerm2 or Kitty graphics
  protocol.
- Use OSC 8 hyperlinks, OSC 52 clipboard access, OSC 133 prompt markers,
  bracketed paste, focus reports, and synchronized output.

### Shell and macOS integration

- Load shell integration automatically for supported Zsh, Fish, Nushell,
  Elvish, and Bash sessions.
- Open a new tab in the current working directory.
- Move to the previous or next semantic shell prompt.
- Select and search terminal text with native macOS controls.
- Export the buffer or the current selection, and print terminal text.
- Receive terminal-bell attention and Dock badge notifications.
- Check for signed updates in the application.

### Rendering and reliability

- Use Metal to render the terminal, with a Core Graphics fallback.
- Keep the interface responsive while the terminal receives large amounts of
  output.
- Reduce graphics work for hidden, occluded, or minimized windows.
- Detect damaged settings data and restore an available backup.

See the [complete feature list](https://tecolot.com/#features) for more detail.

## Install

Tecolot requires **macOS 15.5 or later**.

1. Download the DMG from the
   [latest GitHub release](https://github.com/migueldeicaza/tecolot/releases/latest).
2. Open the DMG.
3. Drag `Tecolot.app` to the Applications folder.
4. Open Tecolot from Applications.

Release builds are signed and notarized. Tecolot can use Sparkle to check for
and install later updates.

## Get started

Tecolot opens your login shell when it starts. Open **Tecolot > Settings** to
choose a default profile or create a profile for a specific task. New windows
use the default profile. You can also select a profile when you open a window
or tab.

Useful default shortcuts:

| Action | Shortcut |
| --- | --- |
| New window | Command+N |
| New tab | Command+T |
| Split pane vertically | Command+D |
| Split pane horizontally | Command+Shift+D |
| Select the previous or next pane | Command+[ or Command+] |
| Select a pane by direction | Command+Option+Arrow |
| Zoom or restore the selected pane | Command+Shift+Return |
| Clear scrollback | Command+K |
| Find terminal text | Command+F |
| Open the theme browser | Command+Control+T |

You can change terminal key mappings in each profile. For more setup details,
see the [getting-started guide](https://tecolot.com/#docs).

## Build from source

The known build environment is Xcode 26.x. Continuous integration currently
uses Xcode 26.6. The first build needs internet access to resolve Swift package
dependencies.

Clone the repository and open the project:

```sh
git clone https://github.com/migueldeicaza/tecolot.git
cd tecolot
open Tecolot.xcodeproj
```

Select the `Tecolot` scheme in Xcode, then build and run the application.

You can also build an unsigned debug application from the command line:

```sh
xcodebuild -resolvePackageDependencies \
  -project Tecolot.xcodeproj \
  -scheme Tecolot

xcodebuild build \
  -project Tecolot.xcodeproj \
  -scheme Tecolot \
  -configuration Debug \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -derivedDataPath ./build \
  CODE_SIGNING_ALLOWED=NO

open ./build/Build/Products/Debug/Tecolot.app
```

Run the test suite with this command:

```sh
xcodebuild test \
  -project Tecolot.xcodeproj \
  -scheme Tecolot \
  -configuration Debug \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -derivedDataPath ./build \
  CODE_SIGNING_ALLOWED=NO
```

## Help and contributions

- Use [GitHub Issues](https://github.com/migueldeicaza/tecolot/issues) for bugs,
  feature requests, and terminal compatibility problems. For a compatibility
  problem, include the command, shell, and steps that reproduce it.
- Use [Discord](https://discord.com/invite/rgN3yzHg8G) for questions and project
  discussion.
- Pull requests are welcome. Build the application and run the test suite
  before you submit a change.

## License

Tecolot is available under the [MIT License](LICENSE). See the bundled
[Nerd Font notices](Tecolot/NerdFont/NerdFontResources/THIRD_PARTY_NOTICES.md)
and [shell-integration license](Tecolot/Profiles/Resources/shell-integration/LICENSE)
for third-party attribution.
