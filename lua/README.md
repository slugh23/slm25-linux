# slm25 — Lua 5.4 library and tool for the SLM-25

- `slm25.lua`: the SLM-25 protocol as a Lua module (pure Lua 5.4)
- `slm25tool.lua`: a Lua recreation of `../slm25.py`, showing how to use the module

The USB side comes from the **ch9326** C module, in
[CH9326LinuxTest](https://github.com/slugh23/CH9326LinuxTest) (branch `lua`, folder
`lua/`). Build it there with `make`. The simulator (`--simulate`, `slm25.simulator()`)
works without it.

## Tool

```bash
export LUA_CPATH="/path/to/CH9326LinuxTest/lua/?.so;;"   # unless ch9326.so is installed
./slm25tool.lua identify
./slm25tool.lua live --repeat 10 --interval 1
./slm25tool.lua recording --csv rec.csv
./slm25tool.lua --help
```

The commands and output match `../slm25.py`. See the main README.

## Library

```lua
package.path = "/path/to/slm25-linux/lua/?.lua;" .. package.path
local slm25 = require "slm25"

local m = assert(slm25.open())                 -- first CH9326, set to 115200 8N1
print(m:identify())                            -- TL202  true

local l = m:live()
print(slm25.format_time(l.clock), l.level, l.weighting, l.response, l.recording)
--> 2026-10-04 19:32:49  36.9  A  SLOW  false

local p = slm25.decode_params(m:read_params())
print(p.serial, p.name, p.total, p.interval, p.alarm_low, p.alarm_high)

local r = m:recording()                        -- current recording
for n, db in ipairs(r.levels) do
  print(slm25.format_time(r.start + (n - 1) * r.interval), db)
end
m:close()
```

| Call | Returns / does |
|---|---|
| `slm25.open([index] [, opts])` | Meter on CH9326 device `index`, or `nil, message`. `opts.verbose = true` logs every packet |
| `slm25.new(transport [, opts])` | Meter on any object with `write`, `read(n, timeout)`, `flush`, `close` |
| `slm25.simulator()` | A simulated meter (a transport) |
| `m:identify()` | Model string (`"TL202"`), and whether it's what NoiseLogger expects |
| `m:live()` | `{clock, level, weighting, response, recording, count, alarm_low, alarm_high, raw}` |
| `m:read_params([status])` | Raw 81-byte settings block; `status = true` for the current/last recording's block |
| `slm25.decode_params(raw)` | `{address, serial, name, total, interval, weighting, response, alarm_low, alarm_high, start_mode, setting_time, start_time, test_records, alarm_under, alarm_over, …}` |
| `slm25.update_params(raw, changes)` | New block with fields changed (`total`, `interval`, `alarm_low`, `alarm_high`, `weighting`, `response`, `start_mode`, …) |
| `m:write_params(raw [, {keep_time}])` | **Writes.** Stores the block, re-arms the meter, sets its clock |
| `m:recording([interval])` | `{start, interval, total, levels = {dB …}, status}` |
| `m:download_block(n)` / `slm25.decode_block(data)` | Raw memory (13 readings per block) |
| `m:start{total, interval}` | **Writes.** Start a recording now (Immediately mode) |
| `m:stop()` | **Writes.** Stop a running recording |
| `m:set_time([secs])` | **Writes.** Set the meter clock (default: now) |
| `m:raw(bytes [, reply_len])` | Send any command (checksum added) |
| `slm25.format_time(secs)`, `slm25.local_epoch([t])` | Convert meter times (local seconds since 1970) |

Protocol errors (no reply, bad framing) are raised as Lua errors; use `pcall` to handle
them. Meter times are local wall-clock seconds, so `format_time` shows them as-is.
