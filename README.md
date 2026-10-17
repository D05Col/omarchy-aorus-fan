# AORUS Fan Control (Omarchy plugin)

Bar widget for the Gigabyte AORUS WATERFORCE X AIO (X240/X280/X360, USB `1044:7a4d`).
Click the fan icon to pick a fan profile (Zero, Quiet, Balance, Default, Performance, Max)
and a pump profile (Balance, Max), with live fan/pump RPM, coolant and CPU temperature.
Keyboard: arrows move, Enter applies, Esc closes.

## Install

```bash
omarchy plugin add <git-url> --enable
~/.config/omarchy/plugins/dylan.aorus-fan/install-udev.sh
```

### Why a udev rule

Reading status works out of the box. Changing a profile means writing raw HID reports to the
cooler's `/dev/hidraw*` node, which is root-only by default, and the `gigabyte_waterforce`
kernel driver is read-only. `install-udev.sh` installs one two-line rule
(`70-waterforce.rules`) that tags only this device (USB `1044:7a4d`) with `uaccess`, so the
logged-in user, and nobody else, can write to it. It asks for `sudo` once; read the script and
the rule first if you like. Without it the panel still shows status, and a profile change
shows the exact command to run.

## Settings (`shell.json` entry)

- `restoreOnStart` (default `true`): re-apply the saved profile once per boot when the
  shell starts. The profile is saved in `~/.local/state/aorus-fan/state.json`.

## CLI

All device logic is in `bin/aorus-fan` (stdlib Python, no dependencies); the QML is only UI.
Link it into your `PATH` to use it from a terminal:

```bash
ln -s ~/.config/omarchy/plugins/dylan.aorus-fan/bin/aorus-fan ~/.local/bin/aorus-fan

aorus-fan status [--json]            # RPM, duty, coolant and CPU temp, saved profile
aorus-fan set quiet [--pump max]     # zero | quiet | balance | default | performance | max
aorus-fan restore                    # re-apply the saved profile once per boot
```

## Protocol notes

Report ID `0x99`, 6144-byte reports written to the device's `/dev/hidraw*` (found by USB ID
under `/sys/class/hidraw`, never hardcoded). The `gigabyte_waterforce` kernel driver keeps
running, so telemetry is read from its hwmon device, falling back to the status query below.

- Status query `{0x99, 0xDA}`: fan RPM `[2..3]`, pump RPM `[5..6]` (little-endian), fan duty
  `[8]`, pump duty `[9]`, coolant `[13]` + `[14]/10` °C.
- Profile change: `{0x99, 0xE5, 0x01, fan}`, `{0x99, 0xE5, 0x02, pump}`, then the commit
  `{0x99, 0xB6}`, about 20 ms apart. Without the commit nothing persists.
- Fan codes: `0x07` zero, `0x06` quiet, `0x00` balance, `0x02` default, `0x05` performance,
  `0x04` max. Pump: `0x00` balance, `0x04` max.
- Do not send `0xE6` manual curves: the firmware latches into ~88% duty (Performance).
- Measured on one X360 at 26 °C coolant, ~50 °C CPU: quiet 56% (~1,450 RPM), balance 72%
  (~1,800), performance 88% (~2,270), max and default 100% (~2,600). `default` is not a
  gentle curve on this unit.

## License

MIT
