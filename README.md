# Seasons on Mac

**A little weather for your desktop.** Snow settles on window tops, the Dock, and desktop icons. In autumn, individual leaves drift down, gather in piles, and blow around when you move a window or push through them with the cursor.

[**Download for macOS →**](../../releases/latest) &nbsp;·&nbsp; [How it works](docs/TECHNICAL.md) &nbsp;·&nbsp; [Build from source](#build-from-source)

![Seasons on Mac](docs/screenshot.png)

## Install

1. Download the latest **DMG** from [Releases](../../releases).
2. Open it and drag **Seasons On Mac** into Applications.
3. Right-click the app and choose **Open**. macOS will warn that the app is not notarised; this is expected for a small open-source project.
4. The welcome window will offer to enable **Accessibility** for weather on desktop icons. This is optional; the rest works without it.
5. Look for the season icon in the menu bar.

**Requirements:** macOS 12 Monterey or newer, Apple Silicon or Intel.

## Seasons

| Season | What it does |
|---|---|
| **Snow** | Snow falls, settles on windows, the Dock, and desktop icons, and can be pushed around. |
| **Autumn** | Every leaf is its own body. Leaves fall, keep their shape and angle, pile up, and slide off edges. |
| **More** | Spring and summer are planned. Only one season runs at a time. |

Both seasons have **Light**, **Normal**, **Heavy**, and **Shower** density. Shower is the new ultra mode: a full screen of leaves, and with *Leaves never disappear* it keeps growing until the desktop is saturated.

### Autumn extras

- **Leaves never disappear** — settled leaves stay put instead of recycling. Leave it running and the screen fills up.
- **Tilt gravity** — uses the MacBook's built-in motion sensor. Tilt the Mac and gravity shifts; leaves slide toward the lower side. Off by default. Requires a MacBook with the Apple Silicon motion sensor.

## Controls

| Action | What it does |
|---|---|
| Move the cursor through a pile | Ploughs snow / shoves leaves aside |
| Drag a window through leaves | Pushes them like a moving cursor; leaves do not stick to the window |
| Move a window with leaves resting on it | The leaves lag behind and fall off |
| Minimise or close a window | Its snow or leaves drop onto whatever is below |
| Menu bar season icon | Season, density, leaves-never-disappear, tilt gravity, clear, welcome screen, quit |

Snow sticks to window tops and rides with the window. Leaves deliberately do not: they have air resistance, fall off moving windows, and collide with the sides of windows and desktop icons.

## Features

- Snow accumulates on window tops, the Dock, and desktop file icons.
- Autumn leaves are individual bodies with shape, angle, rotation, and pile-aware collisions.
- Leaves collide with each other, window tops and sides, desktop icon sides, the Dock, and the ground.
- Moving windows shove leaves around; leaves on background windows hide behind whichever window is in front.
- Closing a window lets its leaves keep falling.
- Shower mode for both seasons, with an effectively uncapped leaf count in autumn when leaves never disappear.
- Optional tilt gravity from the MacBook motion sensor.
- Full-screen apps and Spaces stay weather-free.
- A native menu bar panel and a small welcome window.
- Universal build for Apple Silicon and Intel.
- Settings persist between launches.

## Build from source

```bash
git clone https://github.com/kaidamiani985-arch/Snow-Home.git
cd Snow-Home
./run.sh
```

`./build.sh` produces a universal **Seasons On Mac.app** for Apple Silicon and Intel. See [docs/TECHNICAL.md](docs/TECHNICAL.md) for build notes, architecture, and known limitations.

## Status

**1.1.0 — Seasons.** Snow is unchanged, autumn is new, and Shower mode plus tilt gravity are ready to try. Feedback is very welcome.

## Credits

Made by [Kai Damiani](https://github.com/kaidamiani985-arch). Built with Swift, AppKit, SwiftUI, Metal, and IOKit. The motion-sensor path follows the community reverse-engineering of the AppleSPU HID accelerometer.
