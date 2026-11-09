# Snow on Mac

**A little snowfall for your desktop.** Snow settles on window tops, the Dock, and desktop icons. Push it around with your cursor, shake a window to knock it loose, and watch it pile up.

[**Download for macOS →**](../../releases) &nbsp;·&nbsp; [How it works](docs/TECHNICAL.md) &nbsp;·&nbsp; [Build from source](#build-from-source)

![Snow on Mac](docs/screenshot.png)

## Install

1. Download the latest **DMG** from [Releases](../../releases).
2. Open it and drag **Snow On Mac** into Applications.
3. Right-click the app and choose **Open**. macOS will warn that the app is not notarised; this is expected for a small open-source project.
4. The welcome window will offer to enable **Accessibility** for snow on desktop icons. This is optional; the rest works without it.
5. Look for the snowflake in the menu bar.

**Requirements:** macOS 12 Monterey or newer, Apple Silicon or Intel.

## Controls

| Action | What it does |
|---|---|
| Move the cursor through a drift | Ploughs the snow around |
| Move the cursor through falling snow | Stirs it out of the way |
| Shake a window left and right | Knocks the snow off |
| Minimise or close a window | Its snow drops onto whatever is below |
| Menu bar snowflake | Snowfall on/off, density, clear snow, welcome screen, quit |

The app starts on **Light** — a quiet dusting. You can switch to Normal or Heavy from the menu bar.

## Features

- Snow accumulates on window tops, the Dock, and desktop file icons.
- Pushing breaks the snow into loose grains that fall and rebuild the pile.
- A varied snowfall with mixed flake sizes and shapes.
- The cursor stirs both the drifts and the snow in the air.
- Minimising or closing a window drops its snow onto the next surface.
- Snow lands on normal and maximised windows.
- Full-screen apps and Spaces stay snow-free.
- A native menu bar panel and a small welcome window.
- Universal build for Apple Silicon and Intel.
- Settings persist between launches.

## Build from source

```bash
git clone https://github.com/kaidamiani985-arch/Snow-Home.git
cd Snow-Home
./run.sh
```

`./build.sh` produces a universal **Snow On Mac.app** for Apple Silicon and Intel. See [docs/TECHNICAL.md](docs/TECHNICAL.md) for build notes, architecture, and known limitations.

## Status

Early preview. The core snowfall is working; I'm still polishing a few things. Feedback and ideas are welcome.

## Credits

Made by [Kai Damiani](https://github.com/kaidamiani985-arch). Built with Swift, AppKit, SwiftUI, and Metal.
