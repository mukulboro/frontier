# Frontier

A menu-bar productivity suite for macOS with a western frontier look. Personal fan project, not
affiliated with Rockstar Games.

| Piece | What it does |
|---|---|
| **Camp** (timer) | Pomodoro with adjustable focus / rest / rounds. While it runs, a campfire takes over the desktop and burns down with the time left, then rekindles through each rest. Optional crackle, and a guitar phrase when a phase ends. |
| **Ledger** (tasks) | Today's tasks with time limits and `#tags`. Finishing raises honor; honor slips as a task enters the last quarter of its time, and faster once it's overdue. Abandoning an open task costs honor too. |
| **Visions** | High honor puts the stag on the desktop, low honor the wolf. |
| **Wheel** | Hold `⌥ Tab`, point, release. Brings a running app forward (switching Spaces) or launches it. `E` or right-click re-equips a slot. The hub shows version, category, memory and uptime. |
| **Cores** | Battery, Wi-Fi, memory and CPU as rings on the desktop. The ring is the live reading, the glyph fill its slow average. Hover a core for the actual number. |

Everything on the desktop sits beneath your windows and can be toggled in **Settings**, including
which display (or all of them) it appears on, and launch at login.

## Build

```sh
make test        # unit tests for the honor, task, timer, wheel and vitals logic
make snapshots   # render every surface to build/snapshots/*.png + numeric audio checks
make selftest    # drive the real wheel end to end (takes focus for ~2 s)
make install     # build, bundle, copy to /Applications and launch
```

Requires macOS 14+ and the Swift toolchain. With Command Line Tools only (no Xcode), the Makefile
builds against the newest pre-27 SDK it finds: the macOS 27 SDK turns SwiftUI's `@State` into a
macro whose plugin ships only with Xcode. See `scripts/sdk-args.sh`.

## Layout

- `Sources/FrontierCore` — pure logic, no UI: `Honor`, `Ledger`/`TaskRules`, `PomodoroEngine`,
  `WheelMath`, `VitalsMonitor`. Everything here is unit-tested.
- `Sources/Frontier` — the app: `AppState` (single source of truth, owns the timers),
  `DesktopController` (per-display desktop windows), `Campfire`, `HonorArt`, `WheelController`,
  `PopoverView`, `FireAudio`, `Snapshots`.
- `Sources/Frontier/Resources` — fonts, silhouettes and the campfire clip. Credits and licenses are
  in `Resources/Art/CREDITS.txt`.

## Notes on staying light

- Nothing ticks unless it has to: the 1 s timer runs only while a pomodoro does, the task timer only
  while a task has a deadline, the vitals sampler only while the cores are shown and the screen is on.
- The campfire is a small hardware-decoded video loop screen-blended over a painted scene, and it
  pauses whenever the desktop is fully covered. A live GPU shader was tried first and rejected: any
  in-process Metal render pass reserves about 100 MB for the process.
- Backdrops are painted once into an IOSurface that the layer displays directly, so one copy exists.
- Sound is synthesized, and the audio engine only runs while something is audible.
