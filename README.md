# Frontier

A menu-bar productivity suite for macOS with a western frontier look. Personal fan project, not
affiliated with Rockstar Games.

| Piece | What it does |
|---|---|
| **Camp** (timer) | Pomodoro with adjustable focus / rest / rounds. While it runs, a campfire takes over the desktop and burns down with the time left, then rekindles through each rest. The sky over the camp follows your clock (dawn, day, dusk, night). Optional crackle, and a guitar phrase when a phase ends. |
| **Pocket watch** | While a phase runs, the menu bar icon becomes a watch whose hand sweeps once per phase, with the time remaining shaded behind it. A rest has a dashed rim. Hover for the exact time; Settings can switch to a countdown, or both. |
| **Camp upgrades** | Honor earned adds up to *renown*, which never fades. As it builds over weeks the camp gains a chopping block, lantern, tent, provisions and finally a wagon. |
| **Ledger** (tasks) | Today's tasks with time limits and `#tags`. Finishing raises honor; honor slips as a task enters the last quarter of its time, and faster once it's overdue. Abandoning an open task costs honor too. |
| **Visions** | High honor puts the stag on the desktop, low honor the wolf. |
| **Wheel** | Hold `⌥ Tab`, point, release. Brings a running app forward (switching Spaces) or launches it. `E` or right-click re-equips a slot. The hub shows version, category, memory and uptime. |
| **Tally** | How much of each coding agent's quota is left, as rings, with when it refills. Asks each tool's own CLI; it never reads their private session files. Token totals from local Claude Code transcripts are available too, behind a setting. |
| **Gramophone** | A second face on the wheel (`R` to flip): play/pause, skip, volume, mute, and a saved playlist. Volume and mute go through CoreAudio and need no permission; play and skip use the system media keys, so they reach Music, Spotify or a YouTube Music tab alike. |
| **Cores** | Battery, Wi-Fi, memory and CPU as rings on the desktop. The ring is the live reading, the glyph fill its slow average. Hover a core for the actual number. |

Everything on the desktop sits beneath your windows and can be toggled in **Settings**, including
which display (or all of them) it appears on, and launch at login.

## Build

```sh
make test        # unit tests for the honor, task, timer, wheel and vitals logic
make snapshots   # render every surface to build/snapshots/*.png + numeric audio checks
make selftest    # drive the real wheel end to end (takes focus for ~2 s)
make signing-identity  # once: stable code signature, so permissions survive reinstalls
make install     # build, bundle, copy to /Applications and launch
```

Requires macOS 14+ and the Swift toolchain. With Command Line Tools only (no Xcode), the Makefile
builds against the newest pre-27 SDK it finds: the macOS 27 SDK turns SwiftUI's `@State` into a
macro whose plugin ships only with Xcode. See `scripts/sdk-args.sh`.

## Layout

- `Sources/FrontierCore` — pure logic, no UI: `Honor`, `Ledger`/`TaskRules`, `PomodoroEngine`,
  `WheelMath`, `VitalsMonitor`, `SkyPhase`, `CampUpgrade`, `UsageScanner`. Everything here is unit-tested.
- `Sources/Frontier` — the app: `AppState` (single source of truth, owns the timers),
  `DesktopController` (per-display desktop windows), `Campfire`, `HonorArt`, `WheelController`,
  `PopoverView`, `FireAudio`, `Snapshots`.
- `Sources/Frontier/Resources` — fonts, silhouettes and the campfire clip. Credits and licenses are
  in `Resources/Art/CREDITS.txt`.

**Permissions.** Everything works with none, except the gramophone's play/skip/previous: posting
media keys needs Accessibility, and without it macOS drops them silently. Settings shows a **Grant
media control** button, and the wheel says so plainly rather than appearing to do nothing. Volume,
mute and the Tally need no permission.

> **Run `make signing-identity` once.** Without it the app is ad-hoc signed, every build gets a
> different signature, macOS treats each install as a new app, and the Accessibility grant is
> revoked. That one-time script creates a self-signed certificate in your login keychain so every
> build carries the same designated requirement, and the grant sticks. `scripts/bundle.sh` uses the
> certificate when it is present and falls back to ad-hoc when it isn't.

**What the Tally costs.** Each check runs `claude -p /usage --no-session-persistence`, which takes
about 4 s and costs Claude Code one request. It only runs while the Tally tab is open, at most once
every ten minutes. Codex and Antigravity publish no quota command, so they are listed as unsupported
rather than guessed at.

Useful when checking visuals: `FRONTIER_SKY=dawn|day|dusk|night` pins the sky, `--demo camp` starts
with a fully built camp, and `FRONTIER_STATE=<path>` keeps a test run away from your real data.

## Notes on staying light

- Nothing ticks unless it has to: the 1 s timer runs only while a pomodoro does, the task timer only
  while a task has a deadline, the vitals sampler only while the cores are shown and the screen is on.
- The campfire is a small hardware-decoded video loop screen-blended over a painted scene, and it
  pauses whenever the desktop is fully covered. A live GPU shader was tried first and rejected: any
  in-process Metal render pass reserves about 100 MB for the process.
- Backdrops are painted once into an IOSurface that the layer displays directly, so one copy exists.
- Sound is synthesized, and the audio engine only runs while something is audible.
- The Tally scans ~650 MB of transcripts in about 2.5 s cold, then only reads what each file has
  grown by. Counting is harder than it looks: one API call is written as several rows (one per
  content block, and again inside a subagent's own transcript), so messages are deduplicated
  globally by id. Counting rows naively overstates usage by roughly 2.2×.
