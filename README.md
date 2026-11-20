# sinty-matrix

The LED matrix service for Sinty OS. On devices with a small LED matrix next to the
main processor, it keeps the matrix controller on Sinty's firmware and lets the
desktop session draw on the matrix.

The first supported device is the Arduino UNO Q (`arduino,imola`), with its 13x8
matrix on the STM32U585 microcontroller.

## How it works

The matrix is driven by a microcontroller, not by Linux. `sinty-matrixd` talks to it
over the serial link between the two chips and asks for its firmware version. When
the controller runs anything else, including the Arduino sketch loader it ships with,
the service flashes `uno-q.bin` itself: it drives the controller's SWD debug port
from three GPIO lines of the main processor, checks the debug port identity before
writing anything, erases and programs the flash, reads it back and restarts the
controller. A flash that keeps failing stops after three attempts; remove
`/var/lib/sinty-matrix/flash-attempts` to try again.

The firmware in `firmware/uno-q` is a small bare-metal program. It scans the 104
charlieplexed LEDs at 100 Hz with 8 brightness levels and shows the last frame it
received.

Session programs connect to `/run/sinty-matrix/socket` (group `singularity-session`)
and send the same packets as the serial protocol in `proto/proto.zig`, without the
framing: a hello gets the matrix size, levels and firmware version back, then frames,
a brightness cap or a clear. The service sends the last frame again every few
seconds, so a controller reset never leaves the matrix dark.

Device profiles live in `/usr/share/sinty-matrix/devices/<compatible>.conf`:

```
serial=/dev/ttyHS1
gpio=500000.pinctrl
swclk=26
swdio=25
reset=38
firmware=/usr/share/sinty-matrix/uno-q.bin
```

`sinty-matrixd` takes an optional profile path as its only argument, for testing a
board before its profile is installed.

`sinty-matrixctl` talks to the running service: `info`, `clear`, `brightness 0-7`,
`fill 0-7`, `levels` and `demo [seconds]`.

## Build

    zig build -Doptimize=ReleaseSafe
    zig build test

`zig build` installs `libexec/sinty-matrixd`, `bin/sinty-matrixctl` and
`share/sinty-matrix/uno-q.bin`; `-Dstrip=true` drops debug information. The
tests include a simulated STM32U5 debug port and flash controller, so the flasher is
exercised bit by bit without a board.

To give the UNO Q back to Arduino App Lab, burn the Arduino loader again with
`arduino-cli burn-bootloader -b arduino:zephyr:unoq`.

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on sinty-matrix. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.

## License

GPL-3.0. The LED pin pairs of the UNO Q matrix come from the board description in
[Zephyr](https://github.com/zephyrproject-rtos/zephyr) (Apache-2.0).
