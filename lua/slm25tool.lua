#!/usr/bin/env lua5.4
--[[
slm25tool.lua - command-line tool for the SLM-25, built on the slm25 Lua module.
A Lua recreation of ../slm25.py, showing how to use the library.

Needs the slm25 module (next to this script) and, for a real meter, the ch9326
C module (CH9326LinuxTest/lua) on LUA_CPATH:

  LUA_CPATH="/path/to/CH9326LinuxTest/lua/?.so;;" ./slm25tool.lua identify
  ./slm25tool.lua --simulate live          # no meter needed
]]

-- Find slm25.lua next to this script, wherever it's run from
local here = (arg[0]:match("^(.*)/[^/]*$") or ".")
package.path = here .. "/?.lua;" .. package.path

local slm25 = require "slm25"

local USAGE = [[
usage: slm25tool.lua [--simulate] [-v] <command> [options]

read-only:
  identify                          handshake; the SLM-25 answers "TL202"
  live [--repeat N] [--interval S] [--raw]
                                    live level, weighting, response, recording state
  params [--second] [--save FILE]   the 81-byte settings block (--second: settings,
                                    start time and results of the current/last recording)
  recording [--interval S] [--csv FILE]
                                    the current recording with timestamps
  download [--start N] [--blocks N] [--csv FILE]
                                    raw memory blocks (13 readings each)
  raw <hex...> [--reply-len N]      send A5 <bytes> <sum>, show the reply

writes to the meter:
  write-params FILE --yes [--keep-time]
                                    write a settings block (e.g. from params --save);
                                    re-arms the meter and sets its clock
  start [--total N] [--interval S]  start a recording now (Immediately mode)
  stop                              stop a running recording
  set-time                          set the meter clock to this computer's local time
  record 40|00                      raw stop command (both values stop)

options:
  --simulate   use a simulated meter      -v   show every packet
]]

local function die(msg) io.stderr:write(msg, "\n"); os.exit(1) end

-- Parse "--flag", "--opt value" and positionals; spec maps option -> "flag"|"number"|"string"
local function parse(args, spec)
  local opts, pos, i = {}, {}, 1
  while i <= #args do
    local a = args[i]
    local key = a:match("^%-%-(.+)$")
    if key then
      local kind = spec[key] or die("unknown option --" .. key .. "\n\n" .. USAGE)
      if kind == "flag" then
        opts[key] = true
      else
        i = i + 1
        local v = args[i] or die("--" .. key .. " needs a value")
        opts[key] = kind == "number" and (tonumber(v) or die("--" .. key .. ": not a number: " .. v)) or v
      end
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end
  return opts, pos
end

local function sleep(s)
  local ok, ch9326 = pcall(require, "ch9326")
  if ok then ch9326.sleep(s) else os.execute(("sleep %.3f"):format(s)) end
end

local function hexdump(s)
  for i = 1, #s, 16 do
    local row = s:sub(i, i + 15)
    print(("  %02X: %-48s %s"):format(i - 1, slm25.hex(row) .. " ",
      (row:gsub("[^\32-\126]", "."))))
  end
end

local function read_file(name)
  local f = assert(io.open(name, "rb"))
  local s = f:read("a"); f:close(); return s
end

local function output(csv)
  if not csv then return io.stdout, function() end end
  local f = assert(io.open(csv, "w"))
  return f, function() f:close() end
end

-- ---------------------------------------------------------------------------
-- Commands: each gets the meter and its own argument list

local commands = {}

function commands.identify(m)
  local name, expected = m:identify()
  print(("Meter identifies as: %q"):format(name))
  if not expected then print("note: NoiseLogger expects exactly 'TL202' and would reject this device") end
end

function commands.live(m, args)
  local o = parse(args, { ["repeat"] = "number", interval = "number", raw = "flag" })
  for i = 1, o["repeat"] or 1 do
    if i > 1 then sleep(o.interval or 1) end
    local l = m:live()
    print(("%s  level %.1f dB%s %s   %s, count %d  (alarm %.1f..%.1f dB)"):format(
      slm25.format_time(l.clock), l.level, l.weighting, l.response,
      l.recording and "RECORDING" or "idle", l.count, l.alarm_low, l.alarm_high))
    if o.raw then
      print(("  raw %s   unknown: bytes 8..10 = %d %d %d"):format(slm25.hex(l.raw), table.unpack(l.unknown)))
    end
  end
end

function commands.params(m, args)
  local o = parse(args, { second = "flag", save = "string" })
  local raw = m:read_params(o.second)
  local p = slm25.decode_params(raw)
  print(("Parameter block (%d bytes, cmd %02X):"):format(#raw, o.second and 6 or 5))
  hexdump(raw)
  print("Decoded:")
  print("  address        " .. p.address)
  print("  serial number  " .. p.serial)
  print("  test name      " .. p.name)
  print("  total records  " .. p.total)
  print("  interval       " .. p.interval .. " s")
  print(("  noise alarm    %.1f .. %.1f dB"):format(p.alarm_low, p.alarm_high))
  print("  setting time   " .. slm25.format_time(p.setting_time))
  print("  start time     " .. slm25.format_time(p.start_time) .. (o.second and "" or "  (only correct with --second)"))
  print("  start mode     " .. (p.start_mode == "manual" and "Manual" or "Immediately"))
  print("  noise level    " .. p.weighting)
  print("  sample level   " .. p.response)
  if o.second then
    print("  test records   " .. p.test_records)
    local hits = {}
    if p.alarm_under then hits[#hits + 1] = "UNDER low limit" end
    if p.alarm_over then hits[#hits + 1] = "OVER high limit" end
    print("  noise alarm    " .. (#hits > 0 and table.concat(hits, ", ") or "Normal"))
  end
  if o.save then
    local f = assert(io.open(o.save, "wb")); f:write(raw); f:close()
    print("saved to " .. o.save)
  end
end

function commands.recording(m, args)
  local o = parse(args, { interval = "number", csv = "string" })
  local r = m:recording(o.interval)
  local out, close = output(o.csv)
  out:write("time,dB\n")
  for n, db in ipairs(r.levels) do
    out:write(("%s,%.1f\n"):format(slm25.format_time(r.start + (n - 1) * r.interval), db))
  end
  close()
  io.stderr:write(("recording started %s: %d readings (total records setting %d, interval %g s%s)%s\n"):format(
    slm25.format_time(r.start), #r.levels, r.total, r.interval,
    o.interval and " from --interval" or "", o.csv and ", written to " .. o.csv or ""))
end

function commands.download(m, args)
  local o = parse(args, { start = "number", blocks = "number", csv = "string" })
  local first, count = o.start or 0, o.blocks or 1
  local out, close = output(o.csv)
  out:write("block,index,raw_hex,u16_le,dB\n")
  for blk = first, first + count - 1 do
    local data = m:download_block(blk)
    for i = 1, #data - 1, 2 do
      local v = string.unpack("<I2", data, i)
      out:write(("%d,%d,%02x%02x,%d,%.1f\n"):format(blk, (i - 1) // 2, data:byte(i), data:byte(i + 1), v, v / 10))
    end
  end
  close()
  if o.csv then print(("wrote %d blocks to %s"):format(count, o.csv)) end
end

function commands.raw(m, args)
  local o, pos = parse(args, { ["reply-len"] = "number" })
  local hex = table.concat(pos):gsub("%s", "")
  if #hex == 0 or #hex % 2 == 1 or hex:find("[^%x]") then die("raw: give whole bytes in hex, e.g. 05 00") end
  local req, rsp = m:raw((hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)), o["reply-len"])
  print("-> " .. slm25.hex(req))
  print("<- " .. (#rsp > 0 and slm25.hex(rsp) or "(no reply)"))
end

commands["write-params"] = function(m, args)
  local o, pos = parse(args, { yes = "flag", ["keep-time"] = "flag" })
  local raw = read_file(pos[1] or die("write-params: give a parameter file"))
  if #raw ~= slm25.PARAMS_SIZE then die(("%s: expected %d bytes, got %d"):format(pos[1], slm25.PARAMS_SIZE, #raw)) end
  if not o.yes then die("this WRITES the meter's settings; add --yes to do it") end
  local written = m:write_params(raw, { keep_time = o["keep-time"] })
  sleep(3)                                     -- the meter is silent for a moment after a write
  local back = m:read_params()
  -- the meter copies the setting time into 0x45..0x48 itself
  local function masked(s) return s:sub(1, 0x45) .. s:sub(0x49 + 1) end
  if masked(back) == masked(written) then
    print(("wrote %d bytes; read-back matches"):format(#written))
  else
    local d = {}
    for i = 1, #written do
      if written:byte(i) ~= back:byte(i) and not (i - 1 >= 0x45 and i - 1 <= 0x48) then
        d[#d + 1] = ("0x%02X: %02X->%02X"):format(i - 1, written:byte(i), back:byte(i))
      end
    end
    print(("wrote %d bytes; read-back DIFFERS at %s"):format(#written, table.concat(d, ", ")))
  end
end

function commands.start(m, args)
  local o = parse(args, { total = "number", interval = "number" })
  local p = slm25.decode_params(m:start{ total = o.total, interval = o.interval })
  sleep(3)
  local l = m:live()
  print(("recording %s: %d readings every %d s (count %d so far)"):format(
    l.recording and "started" or "NOT started", p.total, p.interval, l.count))
end

function commands.stop(m)
  print("stop: " .. (m:stop() and "OK" or "not acknowledged"))
end

commands["set-time"] = function(m)
  print("set time: " .. (m:set_time() and "OK" or "not acknowledged"))
end

function commands.record(m, args)
  local _, pos = parse(args, {})
  local v = pos[1]
  if v ~= "40" and v ~= "00" then die("record: value must be 40 or 00") end
  print(("record control %s: %s"):format(v, m:stop(tonumber(v, 16)) and "OK" or "not acknowledged"))
end

-- ---------------------------------------------------------------------------

local simulate, verbose, cmd, rest = false, false, nil, {}
for _, a in ipairs(arg) do
  if cmd then rest[#rest + 1] = a
  elseif a == "--simulate" then simulate = true
  elseif a == "-v" or a == "--verbose" then verbose = true
  elseif a == "-h" or a == "--help" then io.write(USAGE); os.exit(0)
  else cmd = a end
end
if not cmd then io.stderr:write(USAGE); os.exit(2) end
local run = commands[cmd] or die("unknown command: " .. cmd .. "\n\n" .. USAGE)

local m, err
if simulate then
  m = slm25.new(slm25.simulator(), { verbose = verbose })
else
  m, err = slm25.open(nil, { verbose = verbose })
  if not m then die("error: " .. err) end
end

local ok, e = pcall(run, m, rest)
m:close()
if not ok then die("error: " .. tostring(e)) end
