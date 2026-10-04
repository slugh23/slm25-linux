--[[
slm25.lua - SLM-25 sound level meter protocol (Lua 5.4).

The meter speaks a small framed serial protocol through a WCH CH9326 USB-HID
bridge; see ../SLM-25-PROTOCOL.md. This module only needs a transport with
  t:write(s)  t:read(n, timeout_s) -> string  t:flush()  t:close()
which a ch9326 device (the ch9326 Lua C module) provides directly.

  local slm25 = require "slm25"
  local m = assert(slm25.open())          -- first CH9326, 115200 8N1
  print(m:identify())                     -- "TL202"
  local l = m:live()
  print(l.level, l.weighting, l.response) -- 35.5  A  SLOW
  m:close()

Meter timestamps are "local seconds": seconds since 1970-01-01 in local wall-clock
time, with no time-zone adjustment. slm25.format_time() and slm25.local_epoch()
convert them.
]]

local slm25 = { _VERSION = "1.0" }

local REQ, RSP, ACK = 0xA5, 0x5A, 0x55
local CMD = {
  identify = 0x00, live = 0x01, set_time = 0x02, record = 0x03,
  write_params = 0x04, read_params = 0x05, read_status = 0x06, download = 0x08,
}
slm25.CMD = CMD

local IDENTIFY = "TL202\0\0\0"
local PAGES, PAGE_SIZE = 3, 27
local PARAMS_SIZE = PAGES * PAGE_SIZE
local BLOCK_SIZE, RECORD_SIZE = 26, 2
local TIMEOUT = 0.4                     -- NoiseLogger's read timeout
slm25.PARAMS_SIZE, slm25.BLOCK_RECORDS = PARAMS_SIZE, BLOCK_SIZE // RECORD_SIZE

-- ---------------------------------------------------------------------------
-- Helpers

local function checksum(s)
  local sum = 0
  for i = 1, #s do sum = sum + s:byte(i) end
  return sum & 0xFF
end

-- packet(byte, byte, ..., [string]) -> framed request with checksum
local function packet(...)
  local parts = {}
  for _, v in ipairs({...}) do
    parts[#parts + 1] = type(v) == "string" and v or string.char(v)
  end
  local body = table.concat(parts)
  return body .. string.char(checksum(body))
end
slm25.checksum, slm25.packet = checksum, packet

function slm25.hex(s)
  return (s:gsub(".", function(c) return ("%02X "):format(c:byte()) end):gsub(" $", ""))
end

-- Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm)
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (m > 2 and m - 3 or m + 9) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

-- local_epoch([t]) -> meter time for os.time() value t (default now)
function slm25.local_epoch(t)
  local d = os.date("*t", t or os.time())
  return days_from_civil(d.year, d.month, d.day) * 86400 + d.hour * 3600 + d.min * 60 + d.sec
end

-- format_time(meter_seconds) -> "YYYY-MM-DD HH:MM:SS"
function slm25.format_time(secs)
  return os.date("!%Y-%m-%d %H:%M:%S", secs)
end

local function u16(s, off) return (string.unpack(">I2", s, off + 1)) end
local function u32(s, off) return (string.unpack(">I4", s, off + 1)) end
local function put(s, off, bytes) return s:sub(1, off) .. bytes .. s:sub(off + #bytes + 1) end

-- ---------------------------------------------------------------------------
-- Parameter block (81 bytes; offsets are 0-based as in SLM-25-PROTOCOL.md)

-- decode_params(raw) -> table of known fields (plus .raw)
function slm25.decode_params(raw)
  assert(#raw == PARAMS_SIZE, "parameter block must be 81 bytes")
  local name = raw:sub(0x0B + 1, 0x31)
  local chars = {}
  for i = 1, #name - 1, 2 do                      -- UTF-16LE, NUL-terminated
    local lo, hi = name:byte(i, i + 1)
    if lo == 0 and hi == 0 then break end
    chars[#chars + 1] = (hi == 0 and lo >= 32 and lo < 127) and string.char(lo) or "?"
  end
  return {
    raw = raw,
    address = raw:byte(0x00 + 1),
    serial = raw:sub(0x01 + 1, 0x0A + 1):match("^[^%z]*"),
    name = table.concat(chars),
    total = u16(raw, 0x33),
    interval = raw:byte(0x35 + 1),                -- seconds, 1..60
    work_led = raw:byte(0x37 + 1) ~= 0,           -- no visible effect on the SLM-25
    response = raw:byte(0x39 + 1) ~= 0 and "SLOW" or "FAST",
    alarm_low = u16(raw, 0x3A) / 10,              -- dB
    alarm_high = u16(raw, 0x3C) / 10,
    weighting = raw:byte(0x3E + 1) ~= 0 and "C" or "A",
    setting_time = u32(raw, 0x40),                -- local seconds
    start_mode = raw:byte(0x44 + 1) ~= 0 and "immediately" or "manual",
    start_time = u32(raw, 0x45),                  -- correct in the status block (06) only
    -- status block (06) only: results of the current/last recording
    test_records = u16(raw, 0x49),
    alarm_under = raw:byte(0x4B + 1) & 0x04 ~= 0, -- went below the low limit
    alarm_over = raw:byte(0x4C + 1) & 0x04 ~= 0,  -- went above the high limit
  }
end

-- update_params(raw, changes) -> new raw block with the given fields changed.
-- Supported keys: total, interval, response, weighting, alarm_low, alarm_high,
-- start_mode, work_led, setting_time.
function slm25.update_params(raw, changes)
  assert(#raw == PARAMS_SIZE, "parameter block must be 81 bytes")
  for k, v in pairs(changes) do
    if k == "total" then
      raw = put(raw, 0x33, string.pack(">I2", v))
    elseif k == "interval" then
      assert(v >= 1 and v <= 60, "interval must be 1..60 s")
      raw = put(raw, 0x35, string.char(v))
    elseif k == "work_led" then
      raw = put(raw, 0x37, string.char(v and 1 or 0))
    elseif k == "response" then
      raw = put(raw, 0x39, string.char(v:upper() == "SLOW" and 1 or 0))
    elseif k == "alarm_low" or k == "alarm_high" then
      raw = put(raw, k == "alarm_low" and 0x3A or 0x3C, string.pack(">I2", math.floor(v * 10 + 0.5)))
    elseif k == "weighting" then
      raw = put(raw, 0x3E, string.char(v:upper() == "C" and 1 or 0))
    elseif k == "start_mode" then
      raw = put(raw, 0x44, string.char(v == "immediately" and 1 or 0))
    elseif k == "setting_time" then
      raw = put(raw, 0x40, string.pack(">I4", v))
    else
      error("unknown parameter: " .. tostring(k))
    end
  end
  return raw
end

-- ---------------------------------------------------------------------------
-- Meter

local Meter = {}
Meter.__index = Meter
Meter.__close = function(m) m:close() end

-- slm25.new(transport [, {verbose = bool, log = function(msg)}]) -> meter
function slm25.new(transport, opts)
  opts = opts or {}
  return setmetatable({
    t = transport,
    verbose = opts.verbose,
    log = opts.log or function(msg) io.stderr:write(msg, "\n") end,
  }, Meter)
end

-- slm25.open([index] [, opts]) -> meter | nil, err   (needs the ch9326 module)
function slm25.open(index, opts)
  local ok, ch9326 = pcall(require, "ch9326")
  if not ok then
    return nil, "the ch9326 Lua module is not installed (see CH9326LinuxTest/lua)"
  end
  local dev, err = ch9326.open(index)
  if not dev then return nil, err end
  local cfg, cerr = dev:configure{ baud = 115200, parity = "none", stop = 1, bits = 8, interval = 0x10 }
  if not cfg then dev:close(); return nil, cerr end
  return slm25.new(dev, opts)
end

function Meter:close()
  if self.t then self.t:close(); self.t = nil end
end

-- transact(request, reply_len) -> reply  (raises on a bad or missing reply)
function Meter:transact(req, reply_len)
  self.t:flush()
  if self.verbose then self.log("  -> " .. slm25.hex(req)) end
  self.t:write(req)
  local rsp = self.t:read(reply_len, TIMEOUT)
  if self.verbose then self.log("  <- " .. (#rsp > 0 and slm25.hex(rsp) or "(nothing)")) end
  if #rsp ~= reply_len then
    error(("expected %d-byte reply to cmd %02X, got %d: %s"):format(
      reply_len, req:byte(2), #rsp, #rsp > 0 and slm25.hex(rsp) or "nothing"), 2)
  end
  if rsp:byte(1) ~= RSP or rsp:byte(2) ~= req:byte(2) then
    error("bad reply header: " .. slm25.hex(rsp), 2)
  end
  if checksum(rsp:sub(1, -2)) ~= rsp:byte(-1) then
    self.log(("warning: reply checksum mismatch (got %02X, expected %02X)"):format(
      rsp:byte(-1), checksum(rsp:sub(1, -2))))
  end
  return rsp
end

-- identify() -> model string ("TL202" for the SLM-25)
function Meter:identify()
  local rsp = self:transact(packet(REQ, CMD.identify), 11)
  return rsp:sub(3, 10):match("^[^%z]*"), rsp:sub(3, 10) == IDENTIFY
end

-- live() -> {clock, level, weighting, response, recording, count, alarm_low, alarm_high, raw}
function Meter:live()
  local r = self:transact(packet(REQ, CMD.live), 18)
  local flags = r:byte(11)
  return {
    clock = u32(r, 2),                   -- meter clock, local seconds
    count = u16(r, 6),                   -- total records idle; readings so far when recording
    recording = r:byte(10) == 1,
    weighting = flags & 0x01 ~= 0 and "C" or "A",
    response = flags & 0x10 ~= 0 and "SLOW" or "FAST",
    level = u16(r, 11) / 10,             -- dB, instantaneous
    alarm_low = u16(r, 13) / 10,
    alarm_high = u16(r, 15) / 10,
    unknown = { r:byte(9), r:byte(10), flags },  -- bytes 8-10 (8 is always 3)
    raw = r,
  }
end

-- read_params([status]) -> 81-byte block. status=true reads the status block
-- (06): settings + results of the current/last recording.
function Meter:read_params(status)
  local cmd = status and CMD.read_status or CMD.read_params
  local parts = {}
  for pg = 0, PAGES - 1 do
    local rsp = self:transact(packet(REQ, cmd, pg), 4 + PAGE_SIZE)
    if rsp:byte(3) ~= pg then
      error(("parameter page mismatch: asked %d, got %d"):format(pg, rsp:byte(3)))
    end
    parts[#parts + 1] = rsp:sub(4, -2)
  end
  return table.concat(parts)
end

-- write_params(raw [, {keep_time = bool}]) -> block as read back
-- WRITES. Also re-arms the meter, sets its clock from the setting time (stamped
-- with now unless keep_time), and starts a recording in Immediately mode.
function Meter:write_params(raw, opts)
  assert(#raw == PARAMS_SIZE, "parameter block must be 81 bytes")
  if not (opts and opts.keep_time) then
    raw = slm25.update_params(raw, { setting_time = slm25.local_epoch() })
  end
  for pg = 0, PAGES - 1 do
    local page = raw:sub(pg * PAGE_SIZE + 1, (pg + 1) * PAGE_SIZE)
    local rsp = self:transact(packet(REQ, CMD.write_params, pg, page), 4)
    if rsp:byte(3) ~= pg then
      error(("write page %d: meter acknowledged page %d"):format(pg, rsp:byte(3)))
    end
  end
  return raw
end

-- download_block(n) -> 26 bytes (13 little-endian 0.1 dB records; FF FF = empty)
function Meter:download_block(blk)
  local req = packet(REQ, CMD.download, (blk >> 8) & 0xFF, blk & 0xFF, 0)
  local last
  for _ = 1, 2 do                                -- NoiseLogger retries once
    local ok, rsp = pcall(self.transact, self, req, 5 + BLOCK_SIZE)
    if ok and rsp:sub(3, 4) == req:sub(3, 4) then return rsp:sub(5, -2) end
    last = ok and ("block %d: reply was for a different block"):format(blk) or rsp
  end
  error(last)
end

-- decode_block(data) -> array of dB values (nil entries for empty slots)
function slm25.decode_block(data)
  local out = {}
  for i = 1, #data - 1, RECORD_SIZE do
    local v = string.unpack("<I2", data, i)
    out[#out + 1] = v ~= 0xFFFF and v / 10 or false
  end
  return out
end

-- recording([interval]) -> {start, interval, total, levels = {dB...}, status}
-- The current recording: slot 0 up to the first empty slot (or total records).
function Meter:recording(interval)
  local status = slm25.decode_params(self:read_params(true))
  local levels, blk = {}, 0
  while #levels < status.total do
    local done = false
    for _, v in ipairs(slm25.decode_block(self:download_block(blk))) do
      if not v or #levels == status.total then done = true; break end
      levels[#levels + 1] = v
    end
    if done then break end
    blk = blk + 1
  end
  return {
    start = status.start_time,
    interval = interval or status.interval,
    total = status.total,
    levels = levels,
    status = status,
  }
end

-- set_time([meter_seconds]) -> acknowledged   WRITES
function Meter:set_time(secs)
  secs = secs or slm25.local_epoch()
  return self:transact(packet(REQ, CMD.set_time, string.pack(">I4", secs), 0, 0), 4):byte(3) == ACK
end

-- stop([value]) -> acknowledged   WRITES. Stops a running recording (40 and 00 both do).
function Meter:stop(value)
  return self:transact(packet(REQ, CMD.record, 0, value or 0x40), 4):byte(3) == ACK
end

-- start([{total =, interval =}]) -> new parameter block   WRITES
-- Starts a recording now by writing the settings in Immediately mode.
function Meter:start(opts)
  opts = opts or {}
  local changes = { start_mode = "immediately" }
  if opts.total then changes.total = opts.total end
  if opts.interval then changes.interval = opts.interval end
  return self:write_params(slm25.update_params(self:read_params(), changes))
end

-- raw(body [, reply_len]) -> request, reply   (adds A5 and the checksum)
function Meter:raw(body, reply_len)
  local req = packet(REQ, body)
  self.t:flush()
  self.t:write(req)
  return req, self.t:read(reply_len or 256, TIMEOUT)
end

-- ---------------------------------------------------------------------------
-- Simulated meter (a transport), for trying things without hardware

function slm25.simulator(clock)
  clock = clock or os.time
  local sim = { rx = "", offset = 0, rec_start = nil }
  local p = string.rep("\0", PARAMS_SIZE)
  p = slm25.update_params(p, {
    total = 120, interval = 1, work_led = true, alarm_low = 30, alarm_high = 86,
    setting_time = slm25.local_epoch(),
  })
  p = put(p, 0x00, "\1")
  p = put(p, 0x01, "123456789\0")
  p = put(p, 0x0B, "S\0i\0m\0")
  p = put(p, 0x45, p:sub(0x40 + 1, 0x43 + 1))
  sim.params = p

  local function reply(s) sim.rx = sim.rx .. s .. string.char(checksum(s)) end

  function sim:write(data)
    if #data < 3 or data:byte(1) ~= REQ or checksum(data:sub(1, -2)) ~= data:byte(-1) then
      return #data                               -- a real meter stays silent
    end
    local cmd, body = data:byte(2), data:sub(3, -2)
    local now = slm25.local_epoch(clock()) + self.offset
    if cmd == CMD.identify then
      reply(string.char(RSP, cmd) .. IDENTIFY)
    elseif cmd == CMD.live then
      local total, interval = u16(self.params, 0x33), self.params:byte(0x35 + 1)
      local count, rec = total, 0
      if self.rec_start then
        count = math.min(total, (clock() - self.rec_start) // interval + 1)
        rec = count < total and 1 or 0
      end
      local flags = (self.params:byte(0x39 + 1) ~= 0 and 0x10 or 0) | (self.params:byte(0x3E + 1) ~= 0 and 1 or 0)
      local level = 330 + (clock() * 7) % 150
      reply(string.char(RSP, cmd) .. string.pack(">I4I2", now, count) .. string.char(3, rec, flags)
            .. string.pack(">I2", level) .. self.params:sub(0x3A + 1, 0x3D + 1))
    elseif cmd == CMD.set_time then
      self.offset = string.unpack(">I4", body) - slm25.local_epoch(clock())
      reply(string.char(RSP, cmd, ACK))
    elseif cmd == CMD.record then
      self.rec_start = nil
      reply(string.char(RSP, cmd, ACK))
    elseif cmd == CMD.write_params then
      local pg = body:byte(1)
      if pg >= PAGES or #body ~= 1 + PAGE_SIZE then return #data end
      self.params = put(self.params, pg * PAGE_SIZE, body:sub(2))
      if pg == PAGES - 1 and self.params:byte(0x44 + 1) == 1 then self.rec_start = clock() end
      reply(string.char(RSP, cmd, pg))
    elseif cmd == CMD.read_params or cmd == CMD.read_status then
      local pg = body:byte(1)
      if pg >= PAGES then return #data end
      reply(string.char(RSP, cmd, pg) .. self.params:sub(pg * PAGE_SIZE + 1, (pg + 1) * PAGE_SIZE))
    elseif cmd == CMD.download then
      local blk = string.unpack(">I2", body)
      local recs = {}
      for i = 0, 12 do recs[#recs + 1] = string.pack("<I2", 350 + (blk * 13 + i) % 150) end
      reply(string.char(RSP, cmd) .. body:sub(1, 2) .. table.concat(recs))
    end
    return #data
  end

  function sim:read(n)
    local out = self.rx:sub(1, n)
    self.rx = self.rx:sub(n + 1)
    return out
  end

  function sim:flush() local n = #self.rx; self.rx = ""; return n end
  function sim:close() end

  return sim
end

return slm25
