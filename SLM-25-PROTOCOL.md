# SLM-25 serial protocol (via CH9326)

Recovered by static analysis of `NoiseLogger(EN).exe` V2.1 (MFC, 32-bit) and its
`CH9326DLL.dll` (stock WCH build, 2015). **Every command was then checked on a real
SLM-25** (2026-10-01 and 2026-10-04), and the values matched NoiseLogger's.
Items marked **(?)** are inferred, not proven.

Tool: `slm25.py` in this folder (Python + pyusb) implements all of it. Run
`./slm25.py --help`.

## Transport

| Item | Value |
|---|---|
| USB | CH9326 HID bridge, `1a86:e010` (stock ID, so `lib/ch9326.c` finds it unchanged) |
| UART | **115200 baud, 8N1**, CH9326 interval 0x10 → `ch9326_set(i, B115200, P_NONE, STOP_1, BIT_8, 0x10)` |
| Timeouts | 400 ms read / 400 ms write |
| Flow | strict request → reply; one transaction at a time |
| GPIO | not used |

NoiseLogger can also talk over an ordinary COM port. The byte protocol below is plain
serial, and the CH9326 just carries it.

## Framing

```
request:  A5  cmd  [data...]  sum
reply:    5A  cmd  [data...]  sum
sum = (sum of all preceding bytes) & 0xFF
```

The reply echoes `cmd`, and multi-byte numbers are **big-endian**, except for the logged
records (see `08`). NoiseLogger checks the reply's length, its `5A` start byte and the
echoed command (and the page/block number where there is one). It does **not** verify
the reply checksum. On the real meter, every reply's checksum was correct.

`55` in a reply means OK/ACK.

## Commands

| Cmd | Purpose | Request | Reply |
|---|---|---|---|
| `00` | Identify | `A5 00 A5` | 11 bytes: `5A 00 "TL202" 00 00 00 8E` |
| `01` | Live reading | `A5 01 A6` | 18 bytes: `5A 01` + 15 data + sum |
| `02` | Set clock | `A5 02 t3 t2 t1 t0 00 00 sum` | 4 bytes: `5A 02 55 sum` |
| `03` | **Stop recording** (`xx` = `40` or `00`, both confirmed to stop) | `A5 03 00 xx sum` | 4 bytes: `5A 03 55 sum` |
| `04` | Write parameters (confirmed) | 3× `A5 04 pg <27 bytes> sum` (pg = 0,1,2) | 4 bytes per page: `5A 04 pg sum` |
| `05` | Read parameters | 3× `A5 05 pg sum` | 31 bytes: `5A 05 pg <27 bytes> sum` |
| `06` | Read the settings of the current/last recording, plus its start time | as `05` | as `05` |
| `08` | Download records | `A5 08 bh bl 00 sum` | 31 bytes: `5A 08 bh bl <26 bytes> sum` |

### Notes per command

- **00 Identify:** NoiseLogger sends this right after opening and requires the exact
  reply. "TL202" is the logger board's model; NoiseLogger then uses model code 10
  internally.
- **01 Live** (confirmed). Reply byte offsets:

  | Bytes | Field | Example |
  |---|---|---|
  | 2–5 | Meter clock, local seconds since 1970 (big-endian) | `6A BE 3B D4` = 2026-10-01 10:54:12 |
  | 6–7 | Total records setting when idle. During a recording, and after one stopped with `03 40`, the number of readings so far (4 of 5). Not fully understood: on Oct 1 it showed 120 while the last recording had 38 | `00 78` = 120 |
  | 8 | unknown (always 3 so far) | `03` |
  | 9 | **Recording in progress** (1 = recording; confirmed 2026-10-04) | `00` |
  | 10 | flags: bit `0x10` = **SLOW**, bit `0x01` = **C weighting**: the meter's actual working state | `11` |

  Working state vs display (tested 2026-10-04): at power-up the meter loads its working state
  from the stored settings (`0x39`, `0x3E`), but the display always starts as **dBA FAST**.
  After power-up with SLOW stored, the display said FAST while the flag said SLOW. One press
  of the FAST/SLOW button then toggled the flag to FAST. So the button toggles the working
  state, and the flags, not the display, show what the meter is doing. Writing settings with
  NoiseLogger also applies them immediately. On 2026-10-04 the A/C button toggled bit `0x01`
  the same way (A → C, level ~50 dBA → 60–65 dBC). One A/C press on Oct 1, right after
  power-up, raised the level but did not change the bit; probably the same power-up mismatch.
  After any button press, flags and display agree.

  The level at 11–12 is the **instantaneous** level in the meter's current weighting. Switching
  A→C on the meter raised it (35.1 → 46.8 dB), but no flag shows A/C. MAX/MIN hold only affects the
  display, and the live level keeps moving. Pressing buttons never changes the stored parameter block
  (`05`/`06`).
  | 11–12 | **Current sound level, 0.1 dB** | `01 63` = 35.5 dB |
  | 13–14 | Noise alarm low, 0.1 dB | `01 2C` = 30.0 dB |
  | 15–16 | Noise alarm high, 0.1 dB | `03 5C` = 86.0 dB |
- **02 Set clock:** `t3..t0` = seconds since 1970-01-01 **in local wall-clock time** (a Unix
  timestamp with no time-zone adjustment), big-endian. The two `00` bytes come from a variable
  that is always 0, probably an unused time-zone field.
  Example: 2026-10-01 14:30:00 → `A5 02 6A BE 6E 68 00 00 A5`.
  **Confirmed** on the meter: it replies `5A 02 55 B1` and its clock follows (it was 1.0 s
  behind before, 0.2 s after). It does not change the setting time, the start time
  or the recording.
- **04 Write parameters** (confirmed 2026-10-04): the meter acks each page with `5A 04 pg sum`
  and stores the block exactly; it reads back byte-for-byte. Side effects: the meter **sets its
  clock from `0x40`** (writing an old block wound the clock back 47 min), so stamp the current
  time there first, as NoiseLogger does. The write did **not** erase the current recording or
  change the `06` status block. Right after the write the meter didn't answer for a moment, and
  the live clock took a few seconds to update after a following `02`.
- **Recording lifecycle** (confirmed 2026-10-04, start mode Manual):
  1. **Arm:** write the parameters (`04`). After a recording completes (reaches total records)
     the meter shows **FULL** and ignores REC until parameters are written again. `03 40`/`03 00`
     do not re-arm it.
  2. **Start:** press REC on the meter. The meter does not answer serial requests for a
     moment while starting (flash erase), and `06` gets the start time.
  3. **Stop:** `03 40` ends it immediately (recording flag 1 → 0 within 1 s; 4 of 5 readings
     kept), or it ends by itself at total records.
  Display: **REC** while recording (blinking, apparently once per reading), **FULL** after
  reaching total records, **blank** after a stop. In both ended states REC is ignored until the
  parameters are written again. FULL stays on the display after re-arming, until REC is pressed;
  the meter is armed even though FULL still shows.
  **Immediately mode:** writing the parameters with `0x44` = 1 **starts a recording at once**
  (start time = setting time, first reading within 1 s). That's how to start a recording
  remotely. `03 00` **also stops a running recording**, exactly like `03 40`: flag 1 → 0 within
  1 s, display blank, REC ignored until the next parameter write. When the meter is idle, armed
  or FULL, both values do nothing. No difference between them has been found (2026-10-04).
  Live bytes 6–7 count the readings as they arrive (1, 2, 3, ...).
- **03 Recording:** NoiseLogger maps two internal states (0x40 and 0x80) to `xx = 40` and
  `xx = 00`. It sends this before reading parameters, and the "Stop Recording" button
  exists. Which value means start and which means stop needs testing.
- **04/05 Parameters:** the meter holds an **81-byte parameter block** (3 pages × 27
  bytes) with big-endian fields. Fields confirmed against NoiseLogger's Read
  Parameters:

  | Offset | Field | Example |
  |---|---|---|
  | `0x00` | Address | `01` |
  | `0x01`–`0x0A` | Serial number, ASCII, NUL-terminated | `"221153584"` |
  | `0x0B`– | Test name, UTF-16LE, NUL-terminated (up to `0x30`?) | `"Dork"` |
  | `0x33`–`0x34` | Total records | `00 78` = 120 |
  | `0x35` | **Interval, seconds, 1–60** (NoiseLogger's allowed range; confirmed: changed 1 → 2) | `01` |
  | `0x3A`–`0x3B` | Noise alarm low, 0.1 dB | `01 2C` = 30.0 |
  | `0x3C`–`0x3D` | Noise alarm high, 0.1 dB | `03 5C` = 86.0 |
  | `0x39` | **Sample Level**: 0 = FAST, 1 = SLOW | `01` |
  | `0x3E` | **Noise Level**: 0 = A, 1 = C (confirmed 2026-10-04 by changing only this) | `00` |
  | `0x40`–`0x43` | **Setting time**. Writing the block with `04` also **sets the meter's clock** to this value | 11:56:44 |
  | `0x44` | **Start mode**: 1 = Immediately, 0 = Manual (confirmed 2026-10-04) | |
  | `0x45`–`0x48` | **Start time** of the current recording; correct only in the `06` block (`05` repeats the setting time) | 11:56:53 |

  Experiment, 2026-10-01: changed A→C, FAST→SLOW, Immediately→Manual and total 120→5.
  Exactly `0x34`, `0x39`, `0x3E`, `0x44` and the timestamps changed. The interval
  is `0x35` (confirmed 2026-10-04 by changing only the interval). `0x37` = `01` is still
  unknown. Changing one setting at a time would confirm the rest. Work LED and alarm mode are still to be mapped. When writing, NoiseLogger
  puts the current PC time into the block.

  Recording results, `06` block only (confirmed 2026-10-04, matching NoiseLogger's "Record
  Parameters" rows "Test Records" and "Is ... Alarm"):

  | Offset | Field | Example |
  |---|---|---|
  | `0x49`–`0x4A` | **Test records**: readings in the recording (counts up while recording) | `00 11` = 17 |
  | `0x4B` | **Low-limit alarm flags** (level went below the low limit; display UNDER) | `04` = noise |
  | `0x4C` | **High-limit alarm flags** (level went above the high limit; display OVER) | `04` = noise |

  Bit `0x04` = noise, in both bytes. The other bits are presumably TEMP=1, HUMI=2, CO2=8 for
  NoiseLogger's other loggers **(?)**. Both cases were confirmed by recording with the limits
  set past the room level (2026-10-04). Starting a new recording clears both bytes. NoiseLogger's row list
  also confirms `0x37` = **Work LED** (no visible LED on the SLM-25).

  **`05` vs `06`:** `05` is the stored configuration for the **next** recording, updated by
  Set Parameters. `06` holds the settings the **current/last recording** was made with, plus
  its real start time at `0x45` and a copy of total records at `0x4A`. After a Set Parameters
  that changed only the interval, `05` changed and `06` did not. Decode recordings with `06`.
- **08 Download** (confirmed): `bh bl` = 16-bit block number. Each block carries 26
  data bytes = **13 records of 2 bytes**. A record is the sound level in 0.1 dB,
  **little-endian** (`93 01` = 403 = 40.3 dB). `FF FF` = empty slot. NoiseLogger
  retries a failed block once.

  Memory layout seen on the test meter (two recordings, 1 s interval, total 120):
  - slots 0–119: recording 1 (120 readings, stopped at "total records")
  - slots 120–127: `FF FF`
  - slots 128–165: recording 2 (38 readings)
  - from slot 166 (block 12, record 10): `FF FF` to the end of memory

  After a Set Parameters and a new 5-sample manual recording, the new recording
  **restarted at slot 0**. Slots 5–63 were erased (`FF`), but slots 64–165 still held
  the old data. So the meter erases flash in **64-slot (128-byte) units** as it writes,
  and memory after the current recording can contain **stale data**. Only slot 0 up to
  the first `FF` slot is reliably the current recording. Its start time is `0x45` in
  the `06` block. Multiple recordings without a Set Parameters in between appear to
  start at the next 64- or 128-slot boundary **(?)**.

## Example packets (checksums verified)

```
A5 00 A5                      identify
A5 01 A6                      live reading
A5 05 00 AA / 01 AB / 02 AC   read parameter pages 0..2
A5 08 00 00 00 AD             download block 0
A5 08 00 01 00 AE             download block 1
A5 03 00 40 E8 / A5 03 00 00 A8   recording control
```

## Still to do

1. Parameter byte `0x37` = Work LED per NoiseLogger's labels: flipping it (2026-10-04) changed
   nothing visible. No light while recording either way, and the live data was the same.
   It's probably NoiseLogger's "Work LED", which the SLM-25 lacks (the dialog is shared
   across the logger family). Also still unmapped: alarm mode, and the rest of the
   block. Use one-change experiments in NoiseLogger, or NoiseLogger's serializer at
   `0x4149d0`.
2. Live byte 8: always `03` in every state tried (idle, recording, FULL, A/C, FAST/SLOW,
   MAX/MIN, backlight on). Probably a fixed device/firmware code. The backlight is not
   reported anywhere.
3. Whether the `03` value (`40` vs `00`) changes anything that isn't visible.
4. Where recordings after the first (without a parameter write in between) start in
   memory: the 64- vs 128-slot boundary.

## Where this came from (NoiseLogger V2.1 addresses)

| Function | Address |
|---|---|
| Open + SetRate(115200 8N1) + identify | `0x40ce60`, `0x40efe0` |
| Live reading (01) | `0x40f120` |
| Recording control (03) | `0x40f350` |
| Read parameters (05/06) | `0x40f480` |
| Download block (08) | `0x40f720` |
| Write parameters (04) | `0x40f8e0` |
| Set clock (02) | `0x40fae0` |
| Checksum (byte sum) | `0x41bba0` |
| Time → local seconds | `0x411c00`, `0x4117e0` |
| Record size per model | `0x4082f0` |
