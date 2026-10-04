# slm25-linux

Linux tools and protocol documentation for the **SLM-25 sound level meter**, which
connects over USB through a WCH CH9326 HID-to-serial bridge (`1a86:e010`). The
manufacturer's software, NoiseLogger, is Windows-only. This tool does the same things
from Linux, including on a Raspberry Pi.

- `slm25.py`: a single-file Python tool (Python ≥ 3.7, [pyusb](https://pypi.org/project/pyusb/))
- `SLM-25-PROTOCOL.md`: the full serial protocol, recovered from NoiseLogger and checked
  command by command on a real meter
- `lua/`: the same as a Lua 5.4 library (`slm25.lua`) plus a Lua version of the tool.
  See `lua/README.md`

## Setup (Raspberry Pi OS / Debian / Ubuntu)

```bash
sudo apt install python3-usb          # or: pip install pyusb
sudo cp 99-slm25.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger
```

Then unplug and replug the meter, and check it answers:

```bash
./slm25.py identify                   # → Meter identifies as: 'TL202'
```

The rule gives the `plugdev` group access, which Raspberry Pi OS's default user is
already in. Elsewhere, run `sudo usermod -aG plugdev $USER` and log in again.

## Live readings

```bash
./slm25.py live                       # one reading
./slm25.py live --repeat 60 --interval 1
```
```
2026-10-04 13:56:08  level 35.9 dBA SLOW   idle, count 41  (alarm 30.0..86.0 dB)
```

This shows the meter clock, the current level (0.1 dB resolution) with its weighting
(A/C) and response (FAST/SLOW), whether it's recording, and the alarm limits.

## Recordings and settings

| Command | What it does |
|---|---|
| `params` | Show the settings: address, serial, test name, total records, interval, alarm limits, A/C, FAST/SLOW, start mode, times |
| `params --second` | Settings the current/last recording used, its start time, reading count and alarm result |
| `recording [--csv FILE]` | Download the current recording with a timestamp for each reading |
| `start [--total N] [--interval S]` | **Writes.** Start a recording now (sets start mode Immediately) |
| `stop` | **Writes.** Stop a running recording |
| `params --save F` → edit → `write-params F --yes` | **Writes.** Change settings. Also re-arms the meter and sets its clock |
| `set-time` | **Writes.** Set the meter clock to this computer's local time |
| `download --blocks N` | Raw memory dump (13 readings per block) |
| `raw <hex…>` | Send any command, with the checksum added, and show the reply |

Add `-v` to see every packet, or `--simulate` to try any command without a meter.

**How recording works:** writing the settings arms the meter. In Manual mode the
meter's REC button then starts a recording; in Immediately mode the write itself
starts it. A recording ends at "total records" (display FULL) or on `stop` (display
blank). Either way, the settings must be written again before the next recording.
Starting a recording erases the previous one, so download it first.

## Status

Tested on a real SLM-25 (model string "TL202") from an x86 Linux PC. The tool is
written to run on Raspberry Pi OS too, including buster's older pyusb 1.0.2, but it
hasn't been run on a Pi with the meter attached yet. Open questions are listed at the
end of `SLM-25-PROTOCOL.md`.

## License

MIT. See `LICENSE`.
