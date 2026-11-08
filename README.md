# Ingot

Ingot runs original Xbox games on Macs with Apple silicon, drawn with Metal.

It's a fork of [hakuX](https://github.com/rfandango/hakuX), the Android Xbox
emulator: the game's x86 code runs on hakuX's JIT (a FEX fork) under its
reimplementation of the Xbox kernel, and the game's Direct3D push buffer is
decoded into Metal instead of Vulkan. Audio is the MCPX APU, ported from xemu.
What's Mac-specific:

- a Metal renderer (`hw/xbox/hle/mtl/`) behind the HLE GPU's seam;
- guest memory laid out for 16 KiB host pages (`native/core/vm16k.c` and the
  regrouping in `native/core/vm.c`), so the Xbox's 4 KiB pages map straight
  through instead of trapping;
- Core Audio output and a Cocoa game window (`mac/window.m`);
- the Ingot app, a SwiftUI game library (`mac/ingot/`).

Ingot is not hakuX, and hakuX's author doesn't support it: report Ingot
problems here, not upstream.

## Requirements

- A Mac with Apple silicon, macOS 14.4 or later.
- Your own game images (ISO or XISO), dumped from discs you own.

No BIOS, MCPX ROM or hard disk image is needed. Ingot doesn't include any
copyrighted Xbox software.

## Building

With CMake, Ninja and the Xcode command line tools:

    mac/ingot/build.sh

builds the Metal core and `../build/Ingot.app`. Put your disc images in
`~/Documents/xbox` (or add a folder in Settings) and double-click a game.

For the bare core, `ninja -C ../build/mac-metal xboxrun` and run
`xboxrun <disc image> hdd=<folder>`.

## Reporting a problem

Open an issue at
[github.com/T-BoneMadSkrilla/ingot/issues](https://github.com/T-BoneMadSkrilla/ingot/issues),
one game and one problem per issue, with the game's log attached.

### Getting the log

Every game writes a log while it runs, to `~/Library/Logs/Ingot/<game>.log`.
To find it, choose **Game › Show Logs** in Ingot (or click **Show Log** when
Ingot says a game stopped), or in Finder choose **Go › Go to Folder…** and
enter `~/Library/Logs/Ingot`.

- **Copy the log right after the problem happens.** Starting the same game
  again replaces its log.
- If the game froze, quit it first (Cmd-Q in the game window, or **Game › Stop
  Game** in Ingot), then copy the log.
- Drag the `.log` file into the issue to attach it. Don't paste it into the
  issue text: it can be thousands of lines. If GitHub says it's too large,
  zip it first.

### What to include

- **Ingot version**, from **Ingot › About Ingot**.
- **Your Mac**: the model and chip (M1, M2 Pro, ...) and the macOS version, from
  **Apple menu › About This Mac**.
- **The game**: its name and region (USA, Europe, Japan) and the image format
  (ISO or XISO).
- **What happened**: a crash, a freeze, graphics glitches, wrong or missing
  sound, controls not working, the game not booting.
- **Where it happens**: what you were doing when it happened (the menu, level,
  cutscene or mode), and whether it happens every time from there.
- **Your settings**, if you changed them from the defaults: render scale,
  widescreen, HD modes, uncapped frame rate, language, and a hard disk folder
  other than the default.
- **Your controllers**, for input problems: which ones (Xbox, PlayStation,
  keyboard) and which player each one was.
- **A screenshot or a short video** for anything visual. Cmd-Shift-5 records
  the screen.
- **A save state**, if you made one near the problem (**Ingot Player › Save
  State**, saved in `~/Library/Application Support/Ingot/States/`). Mention you
  have one rather than attaching it: it can be large, and I'll ask for it if
  it helps.

Never attach game images, BIOS or dashboard files, or any other copyrighted
Xbox software. Issues that include them will be closed.

## License

Ingot, like hakuX, is free software under the GNU General Public License,
version 3 or later ([COPYING](COPYING)): anyone who distributes it, or a work
based on it, must make the complete source available under the same license.
The code ported from xemu and the third-party components keep their own
licenses, listed in [LICENSE](LICENSE) and [licenses/](licenses/). hakuX's
own README is kept as [README.hakuX.md](README.hakuX.md).

## Notes

- Ingot is not affiliated with Microsoft or with hakuX.
- "Xbox" is a trademark of Microsoft, used here only to say what Ingot runs.
