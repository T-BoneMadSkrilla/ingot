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

- A Mac with Apple silicon, macOS 14 or later.
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
