# Technical notes

This page keeps the implementation details out of the main README. If you just
want to run the app, see the [README](../README.md).

## Architecture

The app draws two borderless, click-through `NSWindow`s per display:

| Layer | Window level | Draws |
|---|---|---|
| Back | just above the desktop icons | far-plane weather + ground, icon, and Dock piles |
| Front | just above the menu bar, below the notch overlay | weather landing on / falling off windows |

A `ScreenController` owns the two windows for one display. `Season` selects a
`SeasonEngine`; only one season runs at a time. Switching seasons rebuilds the
controllers and resets the inactive season.

The window server is polled (`CGWindowListCopyWindowInfo`) at 60×/s for window
geometry. Bounds do **not** require Screen Recording permission. Cursor handling
only reads `NSEvent.mouseLocation` and `NSEvent.pressedMouseButtons`.

## Snow

Snow uses a height-field-style accumulation model. Every window top becomes a
horizontal platform with a 1-D height profile (2 pt columns) that relaxes toward
an angle of repose, so snow slumps into drifts instead of stacking into columns.
A drift is rendered as a triangle strip with a lit crest; falling snow is
instanced as soft irregular flakes.

Desktop file icons are read through Accessibility (the same permission that lets
an app control the Mac). Finder exposes each icon's real frame even when the
desktop is arranged automatically; screen positions are not stored in
`.DS_Store` in that mode. Each file's artwork is rendered off-screen and its
alpha silhouette becomes a per-column top profile, so snow rests on the actual
shape: a folder's tab, a document's page, an image's preview.

The Dock is a platform too. Its window is a full-screen transparent surface, so
the pill is reconstructed from the Dock's preferences (tile size and item count)
plus the screen's reserved area — no extra permissions.

Windows that cover the whole display including the menu bar are treated as
full-screen and skipped. A normal maximised window (top edge just below the menu
bar) still gets a low cap. While any app is in a full-screen Space the overlay
is hidden entirely. That state is read from SkyLight
(`CGSCopyManagedDisplaySpaces`), because macOS exposes no public API for it.

Shake detection counts left-right reversals of the window origin inside a 450 ms
window; fast dragging has speed but no reversals, so it doesn't false-trigger.
When a shake is detected the attached mass is released as loose flakes with the
window's velocity.

The cursor shoves the drift in discrete bites. Snow only moves when the cursor
has travelled a couple of points, and each shove moves a small block into the
next column. Powder resists being pushed into a taller bank, and the surface
relaxes toward a steep angle of repose.

## Autumn

Every leaf is a separate body in a flat array: position, previous position,
velocity, radius, angle, angular velocity, atlas shape, tint, layer, sleep
state, and the surface it is resting on. Nothing is compressed into a height
field; leaves keep their individual shape and angle on landing.

### Spawning and sleep

Leaves spawn above the screen, fall under gravity, and land on surfaces. A leaf
that has been slow for half a second goes to sleep and stops integrating until
something wakes it (cursor, moving window, tilt, a hard impact, or a surface
that disappears). Sleeping leaves act as static obstacles in the collision
solver, which keeps large piles calm.

Density maps to leaf counts: Light 220, Normal 420, Heavy 700, Shower 1400
initial bodies. Shower starts with every initial body falling, for a much
denser shower. With *Leaves never disappear* on, the pool grows by one body
each time an ambient leaf settles. Shower removes the growth cap entirely;
other densities keep the original 1400 cap.

### Collisions

Leaf-leaf collisions use a spatial hash (48 pt cells) with two relaxation
passes per frame. A small overlap slop prevents jitter; positional correction is
split by area. Sleeping leaves are treated as static unless the impact is hard.
Draw order is quantised by depth with a stable index tie-breaker so dense piles
do not flicker.

Windows and desktop icons are solid to front-layer leaves. A leaf pushed into a
window side is moved back out with a low-restitution bounce; window tops remain
landing surfaces. The floor is clamped after the leaf-collision pass so a
compressed pile cannot squeeze a leaf through it.

### Window interaction

Window tops are landing surfaces. Unlike snow, leaves are **not** rigidly
translated when a window moves. Moving a window:

1. Releases any leaves resting on it, with a small opposite drag (air
   resistance) and a short no-support window so they peel off.
2. Pushes nearby leaves with a soft rectangle falloff, similar to the cursor.
   Horizontal force dominates; vertical force is deliberately small.
3. Skips the moving surface as a landing candidate until it stops.

Leaves on a window that is stacked behind another window are hidden when the
front window covers them. The check runs every frame, so bringing a window
forward or backward adapts immediately. When a window closes or minimises, its
leaves are woken and fall; if they were behind a higher window, they switch to
the back layer so they do not pop through it.

### Space transitions

A three-finger Space swipe slides every window sideways. The engine detects
large coordinated window movement while the mouse is still and freezes the
simulation for the gesture. After the swipe it drops the old window surfaces and
rebuilds them, so the leaf pile does not get dragged across the desktop.

## Tilt gravity

On Apple Silicon MacBooks the MEMS accelerometer and gyroscope live behind the
undocumented `AppleSPUHIDDevice` in the IOKit registry (vendor usage page
`0xFF00`; usage 3 is the accelerometer, usage 9 the gyroscope). The app:

1. Matches `AppleSPUHIDDriver` services and sets
   `SensorPropertyReportingState`, `SensorPropertyPowerState`, and
   `ReportInterval` to wake the sensor.
2. Opens the accelerometer HID device with `IOHIDDeviceCreate` /
   `IOHIDDeviceOpen`.
3. Registers an input-report callback. Reports are 22 bytes; x/y/z are
   little-endian `Int32` at offsets 6, 10, and 14, scaled by 65536 to g.
4. Decimates ~8×, low-passes x/y, subtracts the reference captured when the
   toggle was enabled, and maps the tilt to a 2-D screen-space gravity vector.
   The sign of the z axis flips the default vertical when the laptop is turned
   over, so the full 360° range is covered: upside down sends leaves to the top
   of the screen.
5. The autumn engine smooths toward that vector, wakes settled leaves when the
   direction changes significantly, and treats all four screen edges as
   containers so piles can form on any border.

The toggle is off by default, only runs in autumn while the weather is enabled,
and is disabled automatically on Macs without the sensor. No root helper is
needed on the tested Apple Silicon MacBook Air; the app opens the HID device
directly. `NSInputMonitoringUsageDescription` is present in case macOS asks for
Input Monitoring permission.

## Build notes

The project builds with the macOS Command Line Tools; a full Xcode install is
not required.

- `build.sh` uses `swiftc` directly rather than SwiftPM. On the development
  machine the default CLT SDK did not match the installed Swift compiler, so the
  script prefers `/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk` when
  it exists and otherwise falls back to `xcrun --show-sdk-path`. Override with
  `SNOW_SDK=/path/to/SDK ./build.sh`.
- Metal shaders are compiled at process start with
  `MTLDevice.makeLibrary(source:)`, because the offline `metal` compiler ships
  with Xcode rather than the CLT.
- The app is not notarised, so the first launch may need
  **System Settings → Privacy & Security → "Open Anyway"** or right-click the
  app → Open.
- `build.sh` produces a universal binary for Apple Silicon (`arm64`) and
  Intel (`x86_64`), with a minimum deployment target of macOS 12 Monterey.

## Layout

```
Sources/
  Geometry.swift       coordinate conversion (CG top-left <-> per-screen local)
  WindowTracker.swift  window list polling, velocity, shake detection
  IconTracker.swift    desktop icon frames (Accessibility) + artwork silhouettes
  Season.swift         season enum, engine protocol, density leaf counts
  SnowEngine.swift     snow particles, platforms, accumulation, cursor, meshing
  AutumnEngine.swift   leaf bodies, collisions, window interaction, tilt gravity
  Renderer.swift       snow Metal pipelines and triple-buffered vertex uploads
  AutumnRenderer.swift leaf Metal pipeline and instance buffers
  Shaders.swift        snow, drift, and leaf shader source (compiled at runtime)
  TiltGravity.swift    AppleSPU HID accelerometer reader
  OverlayWindow.swift  the two overlay windows
  ScreenController.swift  one engine + two windows per display
  AppDelegate.swift    app lifecycle, menu bar item, settings
  UI.swift             SwiftUI menu popover + first-run welcome window
  main.swift
Resources/Info.plist
Resources/Leaves.png    8-shape leaf atlas
docs/dmg-background.png installer background
Tools/makeicon.swift    generates the app icon
```

## Known limitations

- The Dock strip width is estimated from the Dock's tile size and item count, so
  it can be a few points off after heavy Dock customisation or magnification.
  Nothing is shown when the Dock is auto-hidden or the system is hiding it.
- Full-screen detection uses an undocumented SkyLight symbol. If it ever goes
  away, the app just behaves as if nothing is full-screen.
- Tilt gravity depends on an undocumented AppleSPU HID interface. It is tested
  on an M2 MacBook Air; Intel Macs and some Apple Silicon configurations do not
  expose the sensor. The toggle disables itself when the accelerometer is
  missing.
- Desktop icon weather requires **System Settings → Privacy & Security →
  Accessibility**. Without it the rest of the effect runs normally; only the
  icon platforms are skipped.
- Shower mode is intentionally heavy. With *Leaves never disappear* on, the
  leaf pool keeps growing without a cap; lower densities keep the original
  1400 cap.
