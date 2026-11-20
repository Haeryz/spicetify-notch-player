# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Notch Player: a Dynamic-Island style Spotify player for the MacBook notch. There are two parts that must stay in sync:

- `notchPlayer.js`: a Spicetify extension that runs inside Spotify's Chromium UI. It reads player state, queue, lyrics and audio analysis, and executes controls. `manifest.json` is its Spicetify Marketplace entry.
- `app/NotchPlayer.swift`: the native macOS app, a single SwiftUI/AppKit file. It draws the island fused to the physical notch.

## Build and check

There is no test suite, linter or package manager.

```sh
app/build.sh   # universal "app/build/Notch Player.app" (writes Info.plist, ad-hoc signs)
# fast compile check, one arch:
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o /tmp/np app/NotchPlayer.swift
# JS syntax check (node is not installed):
osascript -l JavaScript -e 'ObjC.import("Foundation"); new Function($.NSString.stringWithContentsOfFileEncodingError("notchPlayer.js",4,null).js); "ok"'
```

- **Run the app:** `pkill -f "Notch Player.app/Contents/MacOS/NotchPlayer"; open "app/build/Notch Player.app"`. The app only owns WebSocket port 47823 once, so stop the running copy before launching another.
- **Screenshots without screen-recording permission:** `"app/build/Notch Player.app/Contents/MacOS/NotchPlayer" --snap <dir>`. This writes `collapsed.png`, `flash.png` and `expanded.png`, then quits. Spotify and the extension must be connected so there is a track to show. `preview.png` and `preview-collapsed.png` are refreshed from these snapshots. Snapshot mode replaces the device name with "MacBook Pro" so personal names stay out of screenshots.
- **Deploy extension changes:** run `cp notchPlayer.js ~/.config/spicetify/Extensions/`, then `spicetify apply`. The apply step restarts Spotify, so ask the user first.

## Toolchain constraint

The build uses the Command Line Tools, not Xcode, and they ship no SwiftUI macro plugin. **`@State` and other SwiftUI macros fail to compile.** Use a stored `State` with a computed accessor instead, following the existing views:

```swift
private let hoverS = State<Bool>(initialValue: false)
private var hover: Bool { get { hoverS.wrappedValue } nonmutating set { hoverS.wrappedValue = newValue } }
```

The deployment target is macOS 13. Newer APIs (symbol effects, the audio tap, `CATapDescription.bundleIDs`) must be behind `#available` checks.

## Bridge protocol (extension ↔ app)

- **Transport:** `ws://127.0.0.1:47823`. The app is the server (`Bridge`), and the extension connects and auto-reconnects.
- **Extension → app:** `snapshot()` in the JS is decoded as `PlayerState` in Swift. It is sent on events and every 3 s.
  - Synthesized `Decodable` requires every non-optional key. When you add a field, add it to both sides, or make it optional in Swift. Otherwise every message fails to decode silently and the notch disappears.
- **App → extension:** commands like `{cmd: "toggle" | "next" | "seek" | "volume" | "open" | …}`, handled by `runCommand`. The app broadcasts to every connection, so a second connected copy of the extension would run each command twice.
- **Payloads sent once per track:**
  - `viz` is Spotify's audio analysis (`Spicetify.getAudioData`), compacted into `segs` and `beats`. It is sent only in the first push per track (`vizSentFor`), and the app keeps the previous `viz` while the URI is unchanged.
  - `lyrics` is sent on every push.
- When the app is connected, the extension adds `np-bridged` to its root, which hides the in-Spotify pill.

## Native app architecture (`app/NotchPlayer.swift`)

- **`NotchModel`** holds all UI state. `apply()` merges incoming `PlayerState`, loads artwork, and derives `accent` and the blurred `ambient` backdrop. On a song change it triggers `flashTitle()`, a short widening of the compact pill.
- **Song changes must never expand the island.** The user explicitly rejected auto-expanding. The JS equivalent is the opt-in setting `expandOnSongChange`, which is off by default. `README.md` still says the island expands on song change; that line is out of date.
- **`AppDelegate`:**
  - Owns a borderless `NotchPanel` above the menu bar.
  - Polls the mouse at 30 Hz (`trackMouse`/`activeRect`) and sets `model.expanded` on hover, with a 0.3 s leave delay.
  - `activeRect` must mirror the sizes computed in `NotchRoot.size`.
- **Animation sync:**
  - The island shape and its contents use one spring, `kIslandSpring`.
  - The expanded height is calculated (`NotchModel.openBodyH` from the `kRow*`/`kGap` constants), not measured. Every row in `ExpandedView` has a matching fixed `.frame(height:)`. Keep these in step when changing the layout, or the island will resize a second time after opening.
  - On close, content stays mounted (`contentMounted`, removed 0.6 s later) and fades with `.opacity`/`.scaleEffect`. A SwiftUI removal transition there was dropped instantly.
- **Visualizer sources, in priority order:**
  1. **Live audio.** `SpotifyAudioTap` (macOS 14.2+) creates a Core Audio process tap on `com.spotify.client` plus a private aggregate device. `Spectrum` runs a 2048-point FFT and reduces it to 4 bands. `AudioLevels` keeps a timestamped history and reads it back delayed by the output device's latency. Bluetooth headphones add roughly 300 ms, so without this delay the bars run ahead of what the user hears.
  2. **Beat data.** `Viz.levels(at:)` uses the analysis loudness envelope and beats, with the same latency offset.
  3. **Idle pulse.** Deliberately calm; the user objected to random-looking motion.
  - The menu-bar item shows which source is active. Live audio needs the System Audio Recording permission (`NSAudioCaptureUsageDescription` is set in `build.sh`).

## Extension notes (`notchPlayer.js`)

- It is one IIFE that retries until `Spicetify.Player`/`Platform` are ready.
- It builds its own DOM (`#np-root`) and CSS (`#np-style`).
- Settings are in `Spicetify.LocalStorage` under `notch-player:settings`. Saved values override defaults, so renaming a key is the only way to change the default for existing users.
- `vizLevels()` mirrors Swift's `Viz.levels(at:)`. Keep the formulas identical.
- Spotify's Chromium cannot reach the audio stream, so the in-Spotify pill can only use beat data.
- Live debugging: when Spotify runs with `--remote-debugging-port=9229`, the page can be driven over CDP (`http://localhost:9229/json`). This allows previewing changes without `spicetify apply`. Hide the installed root first, never open a second bridge connection that handles commands, and restore the page afterwards.
