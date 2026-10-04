#!/usr/bin/env python3
"""
slm25.py - talk to an SLM-25 sound level meter (CH9326 USB-HID bridge) from Linux.

Protocol: see SLM-25-PROTOCOL.md (recovered from NoiseLogger V2.1 and checked
against a real SLM-25). The CH9326 USB layer is described there too.

Requires pyusb (`pip install pyusb`, or `sudo apt install python3-usb`) and
access to the device (99-slm25.rules, or run as root). Python >= 3.7.

Examples:
    slm25.py identify
    slm25.py live --repeat 5
    slm25.py params
    slm25.py recording --csv rec.csv   # current recording, timestamped
    slm25.py download --blocks 4 --csv out.csv
    slm25.py raw 01                 # send A5 01 <sum>, show the reply
    slm25.py --simulate live        # no hardware needed
"""

import argparse
import datetime
import sys
import time

# --- CH9326 / USB -----------------------------------------------------------

CH9326_VID, CH9326_PID = 0x1A86, 0xE010
EP_OUT, EP_IN = 0x02, 0x82
REPORT_SIZE = 32
PAYLOAD_MAX = REPORT_SIZE - 1

# CH9326 UART setup report (see SLM-25-PROTOCOL.md, "USB layer"): 115200 8N1
BAUD_115200 = (0x83, 0xCC)
CFG_8N1 = 0xC0 | 0x04 | 0x03      # no parity, "1 stop" bit as the vendor lib sets it, 8 bits
RX_INTERVAL = 0x10                # value NoiseLogger uses

# --- SLM-25 protocol --------------------------------------------------------

REQ, RSP, ACK = 0xA5, 0x5A, 0x55
CMD_IDENTIFY, CMD_LIVE, CMD_SET_TIME, CMD_RECORD = 0x00, 0x01, 0x02, 0x03
CMD_WRITE_PARAMS, CMD_READ_PARAMS, CMD_READ_PARAMS2 = 0x04, 0x05, 0x06
CMD_DOWNLOAD = 0x08

IDENTIFY_REPLY = bytes([RSP, 0x00]) + b"TL202" + bytes(3)
PARAM_PAGES, PARAM_PAGE_SIZE = 3, 27
BLOCK_DATA_SIZE, RECORD_SIZE = 26, 2      # model "TL202": 13 two-byte records per block
TIMEOUT_S = 0.4                           # NoiseLogger's read timeout


def checksum(data):
    return sum(data) & 0xFF


def packet(*body):
    body = bytes(body)
    return body + bytes([checksum(body)])


def hexs(data):
    return " ".join("%02X" % b for b in data)


class ProtocolError(Exception):
    pass


# --- Transports -------------------------------------------------------------

class CH9326Transport:
    """Byte stream to the meter's UART through the CH9326, using pyusb."""

    def __init__(self):
        try:
            import usb.core
            import usb.util
        except ImportError:
            sys.exit("pyusb is required: pip install pyusb  (or: sudo apt install python3-usb)")
        self._usb = usb
        self.dev = usb.core.find(idVendor=CH9326_VID, idProduct=CH9326_PID)
        if self.dev is None:
            raise ProtocolError("no CH9326 (1a86:e010) found - is the meter plugged in?")
        self._reattach = False
        try:
            if self.dev.is_kernel_driver_active(0):
                self.dev.detach_kernel_driver(0)
                self._reattach = True
        except (NotImplementedError, usb.core.USBError):
            pass
        try:
            usb.util.claim_interface(self.dev, 0)
        except usb.core.USBError as e:
            if getattr(e, "errno", None) == 13:
                raise ProtocolError("permission denied opening the CH9326 - install "
                                    "99-slm25.rules (see README) or run with sudo")
            raise ProtocolError("cannot open the CH9326: %s" % e)
        self._rx = bytearray()
        self._configure_uart()

    def _configure_uart(self):
        report = bytes([0xFF, CFG_8N1, BAUD_115200[0], BAUD_115200[1], RX_INTERVAL])
        report += bytes(REPORT_SIZE - len(report))
        # HID SET_REPORT (Output, ID 0) on interface 0
        self.dev.ctrl_transfer(0x21, 0x09, 0x0200, 0, report, 1000)

    def write(self, data):
        for i in range(0, len(data), PAYLOAD_MAX):
            chunk = data[i:i + PAYLOAD_MAX]
            report = bytes([len(chunk)]) + chunk
            if len(chunk) == PAYLOAD_MAX:
                report += bytes(REPORT_SIZE - len(report))   # full 32-byte report
            # partial chunks go out short (len + 1 bytes), as the vendor lib does
            self.dev.write(EP_OUT, report, 1000)

    def _poll(self, timeout_ms):
        try:
            report = bytes(self.dev.read(EP_IN, REPORT_SIZE, timeout_ms))
        except self._usb.core.USBError as e:
            # pyusb >= 1.1 raises USBTimeoutError; older versions (e.g. Raspbian
            # buster's 1.0.2) raise USBError with errno 110 (ETIMEDOUT)
            timeout_cls = getattr(self._usb.core, "USBTimeoutError", None)
            if (timeout_cls and isinstance(e, timeout_cls)) or getattr(e, "errno", None) == 110:
                return False
            raise
        if report:
            n = min(report[0], len(report) - 1)
            self._rx += report[1:1 + n]
        return True

    def read(self, count, timeout=TIMEOUT_S):
        """Read up to count bytes; return early only on timeout."""
        deadline = time.monotonic() + timeout
        while len(self._rx) < count:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            self._poll(max(1, int(left * 1000)))
        out, self._rx = bytes(self._rx[:count]), self._rx[count:]
        return out

    def flush(self):
        while self._poll(20):
            pass
        self._rx.clear()

    def close(self):
        self._usb.util.release_interface(self.dev, 0)
        if self._reattach:
            try:
                self.dev.attach_kernel_driver(0)
            except self._usb.core.USBError:
                pass
        self._usb.util.dispose_resources(self.dev)


class SimulatedMeter:
    """Fake SLM-25 that answers per SLM-25-PROTOCOL.md. For trying the tool offline."""

    def __init__(self):
        self._rx = bytearray()
        # Parameter block laid out like a real SLM-25's (serial and name changed)
        self.params = p = bytearray(PARAM_PAGES * PARAM_PAGE_SIZE)
        p[0] = 1                                          # address
        p[0x01:0x0B] = b"123456789\0"                     # serial number
        p[0x0B:0x0B + 6] = "Sim".encode("utf-16-le")       # test name
        p[0x33:0x35] = (120).to_bytes(2, "big")            # total records
        p[0x35] = p[0x37] = p[0x44] = 1                   # unknown flags (interval is one?)
        p[0x3A:0x3C] = (300).to_bytes(2, "big")            # noise alarm low, 0.1 dB
        p[0x3C:0x3E] = (860).to_bytes(2, "big")            # noise alarm high
        p[0x40:0x44] = p[0x45:0x49] = local_epoch_seconds().to_bytes(4, "big")
        self.recording = 0x40
        self.rec_start = None
        self.clock_offset = 0

    def write(self, data):
        data = bytes(data)
        if len(data) < 3 or data[0] != REQ or checksum(data[:-1]) != data[-1]:
            return                                    # a real meter would stay silent
        cmd, body = data[1], data[2:-1]
        if cmd == CMD_IDENTIFY:
            reply = IDENTIFY_REPLY
        elif cmd == CMD_LIVE:
            now = local_epoch_seconds() + self.clock_offset
            level = 330 + int(time.time() * 7) % 150  # 33.0 .. 47.9 dB, wandering
            # layout as observed on a real SLM-25
            total = int.from_bytes(self.params[0x33:0x35], "big")
            count, rec = total, 0
            if self.rec_start is not None:
                count = min(total, int((time.time() - self.rec_start) // self.params[0x35]) + 1)
                rec = 1 if count < total else 0
            flags = (0x10 if self.params[0x39] else 0) | (0x01 if self.params[0x3E] else 0)
            reply = (bytes([RSP, CMD_LIVE]) + now.to_bytes(4, "big") + count.to_bytes(2, "big")
                     + bytes([0x03, rec, flags]) + level.to_bytes(2, "big")
                     + self.params[0x3A:0x3E])
        elif cmd == CMD_SET_TIME:
            self.clock_offset = int.from_bytes(body[:4], "big") - local_epoch_seconds()
            reply = bytes([RSP, cmd, ACK])
        elif cmd == CMD_RECORD:
            self.recording = body[1]
            reply = bytes([RSP, cmd, ACK])
        elif cmd == CMD_WRITE_PARAMS:
            pg = body[0]
            if pg >= PARAM_PAGES or len(body) != 1 + PARAM_PAGE_SIZE:
                return
            self.params[pg * PARAM_PAGE_SIZE:(pg + 1) * PARAM_PAGE_SIZE] = body[1:]
            if pg == PARAM_PAGES - 1 and self.params[0x44] == 1:
                self.rec_start = time.time()         # Immediately mode: recording starts now
            reply = bytes([RSP, cmd, pg])
        elif cmd in (CMD_READ_PARAMS, CMD_READ_PARAMS2):
            pg = body[0]
            if pg >= PARAM_PAGES:
                return
            page = self.params[pg * PARAM_PAGE_SIZE:(pg + 1) * PARAM_PAGE_SIZE]
            reply = bytes([RSP, cmd, pg]) + page
        elif cmd == CMD_DOWNLOAD:
            blk = int.from_bytes(body[:2], "big")
            recs = b"".join((350 + (blk * 13 + i) % 150).to_bytes(2, "little") for i in range(13))
            reply = bytes([RSP, cmd]) + body[:2] + recs
        else:
            return
        self._rx += reply + bytes([checksum(reply)])

    def read(self, count, timeout=TIMEOUT_S):
        out, self._rx = bytes(self._rx[:count]), self._rx[count:]
        return out

    def flush(self):
        self._rx.clear()

    def close(self):
        pass


# --- Meter commands ---------------------------------------------------------

class SLM25:
    def __init__(self, transport, verbose=False):
        self.t = transport
        self.verbose = verbose

    def transact(self, req, reply_len):
        """Send one request packet, return the reply (checked framing)."""
        self.t.flush()
        if self.verbose:
            print("  -> " + hexs(req), file=sys.stderr)
        self.t.write(req)
        rsp = self.t.read(reply_len)
        if self.verbose:
            print("  <- " + (hexs(rsp) or "(nothing)"), file=sys.stderr)
        if len(rsp) != reply_len:
            raise ProtocolError("expected %d-byte reply to cmd %02X, got %d: %s"
                                % (reply_len, req[1], len(rsp), hexs(rsp) or "nothing"))
        if rsp[0] != RSP or rsp[1] != req[1]:
            raise ProtocolError("bad reply header: " + hexs(rsp))
        if checksum(rsp[:-1]) != rsp[-1]:
            # NoiseLogger doesn't check this; warn so we learn whether it holds
            print("warning: reply checksum mismatch (got %02X, expected %02X)"
                  % (rsp[-1], checksum(rsp[:-1])), file=sys.stderr)
        return rsp

    def identify(self):
        rsp = self.transact(packet(REQ, CMD_IDENTIFY), 11)
        return rsp[2:-1]

    def live(self):
        r = self.transact(packet(REQ, CMD_LIVE), 18)
        # Field layout from NoiseLogger's byte swapping for model TL202; meanings unknown
        return {
            "u32@2": int.from_bytes(r[2:6], "big"),
            "u16@6": int.from_bytes(r[6:8], "big"),
            "u8@8": r[8], "u8@9": r[9], "u8@10": r[10],
            "u16@11": int.from_bytes(r[11:13], "big"),
            "u16@13": int.from_bytes(r[13:15], "big"),
            "u16@15": int.from_bytes(r[15:17], "big"),
            "raw": r,
        }

    def read_params(self, second_set=False):
        cmd = CMD_READ_PARAMS2 if second_set else CMD_READ_PARAMS
        block = b""
        for pg in range(PARAM_PAGES):
            rsp = self.transact(packet(REQ, cmd, pg), 4 + PARAM_PAGE_SIZE)
            if rsp[2] != pg:
                raise ProtocolError("parameter page mismatch: asked %d, got %d" % (pg, rsp[2]))
            block += rsp[3:-1]
        return block

    def write_params(self, block):
        """Write the 81-byte parameter block (cmd 04), 3 pages of 27 bytes."""
        if len(block) != PARAM_PAGES * PARAM_PAGE_SIZE:
            raise ProtocolError("parameter block must be %d bytes" % (PARAM_PAGES * PARAM_PAGE_SIZE))
        for pg in range(PARAM_PAGES):
            page = block[pg * PARAM_PAGE_SIZE:(pg + 1) * PARAM_PAGE_SIZE]
            rsp = self.transact(packet(REQ, CMD_WRITE_PARAMS, pg, *page), 4)
            if rsp[2] != pg:
                raise ProtocolError("write page %d: meter acknowledged page %d" % (pg, rsp[2]))

    def download_block(self, blk, retries=1):
        req = packet(REQ, CMD_DOWNLOAD, blk >> 8, blk & 0xFF, 0)
        for attempt in range(retries + 1):
            try:
                rsp = self.transact(req, 5 + BLOCK_DATA_SIZE)
                if rsp[2:4] == req[2:4]:
                    return rsp[4:-1]
            except ProtocolError:
                if attempt == retries:
                    raise
        raise ProtocolError("block %d: reply was for a different block" % blk)

    def set_time(self, when=None):
        secs = local_epoch_seconds(when)
        rsp = self.transact(packet(REQ, CMD_SET_TIME, *secs.to_bytes(4, "big"), 0, 0), 4)
        return rsp[2] == ACK

    def record_control(self, value):
        rsp = self.transact(packet(REQ, CMD_RECORD, 0, value), 4)
        return rsp[2] == ACK

    def raw(self, body, reply_len=None):
        req = packet(REQ, *body)
        self.t.flush()
        self.t.write(req)
        rsp = self.t.read(reply_len or 256)
        return req, rsp


def local_epoch_seconds(when=None):
    """Seconds since 1970 in local wall-clock time (no timezone adjustment), as the meter uses."""
    when = when or datetime.datetime.now()
    return int((when.replace(tzinfo=None) - datetime.datetime(1970, 1, 1)).total_seconds())


def meter_time(secs):
    """Interpret a meter timestamp (local seconds since 1970)."""
    try:
        return (datetime.datetime(1970, 1, 1) + datetime.timedelta(seconds=secs)).isoformat(" ")
    except OverflowError:
        return "?"


def hexdump(data, width=16):
    for i in range(0, len(data), width):
        row = data[i:i + width]
        print("  %02X: %-*s %s" % (i, width * 3, hexs(row),
                                   "".join(chr(b) if 32 <= b < 127 else "." for b in row)))


# --- CLI --------------------------------------------------------------------

def cmd_identify(m, a):
    ident = m.identify()
    name = ident.rstrip(b"\0").decode("ascii", "replace")
    print("Meter identifies as: %r  (raw %s)" % (name, hexs(ident)))
    if ident != IDENTIFY_REPLY[2:]:
        print("note: NoiseLogger expects exactly 'TL202' and would reject this device")


def cmd_live(m, a):
    for i in range(a.repeat):
        if i:
            time.sleep(a.interval)
        f = m.live()
        # Confirmed against the meter: clock, level, total records, alarm limits
        # byte 10 = working state: bit 0x10 = SLOW, bit 0x01 = C (display can disagree after power-up)
        # byte 9 = recording in progress; bytes 6-7 = total records, or the count so far while
        # recording / after a stop (not fully understood)
        print("%s  level %.1f dB%s %s   %s, count %d  (alarm %.1f..%.1f dB)"
              % (meter_time(f["u32@2"]), f["u16@11"] / 10,
                 "C" if f["u8@10"] & 0x01 else "A",
                 "SLOW" if f["u8@10"] & 0x10 else "FAST",
                 "RECORDING" if f["u8@9"] else "idle", f["u16@6"],
                 f["u16@13"] / 10, f["u16@15"] / 10))
        if a.raw:
            print("  raw %s   unknown: u8@8..10 = %d %d %d"
                  % (hexs(f["raw"]), f["u8@8"], f["u8@9"], f["u8@10"]))


def cmd_params(m, a):
    block = m.read_params(second_set=a.second)
    print("Parameter block (%d bytes, cmd %02X):" % (len(block), 6 if a.second else 5))
    hexdump(block)
    # Confirmed against NoiseLogger's Read Parameters on the real meter
    be16 = lambda off: int.from_bytes(block[off:off + 2], "big")
    print("Decoded:")
    print("  address        %d" % block[0])
    print("  serial number  %s" % block[1:11].split(b"\0")[0].decode("ascii", "replace"))
    name = block[0x0B:0x31]
    name = name[:next((i for i in range(0, len(name) - 1, 2) if name[i:i + 2] == b"\0\0"), len(name))]
    print("  test name      %s" % name.decode("utf-16-le", "replace"))
    print("  total records  %d" % be16(0x33))
    print("  interval       %d s" % block[0x35])
    print("  noise alarm    %.1f .. %.1f dB" % (be16(0x3A) / 10, be16(0x3C) / 10))
    print("  setting time   %s" % meter_time(int.from_bytes(block[0x40:0x44], "big")))
    print("  start time     %s%s" % (meter_time(int.from_bytes(block[0x45:0x49], "big")),
                                      "" if a.second else "  (only correct with --second)"))
    print("  start mode     %s"
          % {0: "Manual", 1: "Immediately"}.get(block[0x44], "? %02X" % block[0x44]))
    print("  noise level    %s" % ("C" if block[0x3E] else "A"))
    if a.second:
        # status block only: results of the current/last recording
        print("  test records   %d" % be16(0x49))
        # 0x4B = below-low-limit flags, 0x4C = above-high-limit flags; bit 0x04 = noise
        hits = [name for off, name in ((0x4B, "UNDER low limit"), (0x4C, "OVER high limit"))
                if block[off] & 0x04]
        print("  noise alarm    %s" % (", ".join(hits) if hits else "Normal"))
    print("  sample level   %s" % ("SLOW" if block[0x39] else "FAST"))
    # Multi-byte fields that NoiseLogger byte-swaps (big-endian) for model TL202
    print("All big-endian fields NoiseLogger uses:")
    for off, size in ((0x31, 2), (0x33, 2), (0x3A, 2), (0x3C, 2), (0x40, 4), (0x45, 4), (0x49, 2)):
        v = int.from_bytes(block[off:off + size], "big")
        extra = "  (%s if a timestamp)" % meter_time(v) if size == 4 else ""
        print("  @0x%02X u%d = %d%s" % (off, size * 8, v, extra))
    if a.save:
        with open(a.save, "wb") as f:
            f.write(block)
        print("saved to " + a.save)


def cmd_download(m, a):
    out = open(a.csv, "w") if a.csv else sys.stdout
    try:
        out.write("block,index,raw_hex,u16_le,dB\n")
        for blk in range(a.start, a.start + a.blocks):
            data = m.download_block(blk)
            for i in range(0, len(data) - RECORD_SIZE + 1, RECORD_SIZE):
                rec = data[i:i + RECORD_SIZE]
                # records are little-endian (unlike the rest of the protocol), 0.1 dB units
                v = int.from_bytes(rec, "little")
                out.write("%d,%d,%s,%d,%.1f\n" % (blk, i // RECORD_SIZE, rec.hex(), v, v / 10))
    finally:
        if a.csv:
            out.close()
            print("wrote %d blocks to %s" % (a.blocks, a.csv))


def cmd_recording(m, a):
    """The current recording: slot 0 up to the first empty slot (or total records)."""
    status = m.read_params(second_set=True)          # cmd 06 has the real start time
    start_secs = int.from_bytes(status[0x45:0x49], "big")
    total = int.from_bytes(status[0x33:0x35], "big")
    # 0x35 = interval in seconds, as in effect for this recording (05 holds the next one's)
    interval = a.interval if a.interval is not None else status[0x35]
    start = datetime.datetime(1970, 1, 1) + datetime.timedelta(seconds=start_secs)
    per_block = BLOCK_DATA_SIZE // RECORD_SIZE
    levels = []
    blk = 0
    while len(levels) < total:
        data = m.download_block(blk)
        for i in range(0, BLOCK_DATA_SIZE, RECORD_SIZE):
            rec = data[i:i + RECORD_SIZE]
            if rec == b"\xff\xff" or len(levels) == total:
                break
            levels.append(int.from_bytes(rec, "little") / 10)
        else:
            blk += 1
            continue
        break
    out = open(a.csv, "w") if a.csv else sys.stdout
    try:
        out.write("time,dB\n")
        for n, db in enumerate(levels):
            t = start + datetime.timedelta(seconds=n * interval)
            out.write("%s,%.1f\n" % (t.isoformat(" "), db))
    finally:
        if a.csv:
            out.close()
    print("recording started %s: %d readings (total records setting %d, interval %g s%s)%s"
          % (start.isoformat(" "), len(levels), total, interval,
             " from --interval" if a.interval is not None else "",
                          ", written to " + a.csv if a.csv else ""), file=sys.stderr)


def cmd_write_params(m, a):
    block = bytearray(open(a.file, "rb").read())
    if not a.keep_time:
        # Writing sets the meter's CLOCK from 0x40 (confirmed), so stamp the current
        # time there, as NoiseLogger does
        block[0x40:0x44] = local_epoch_seconds().to_bytes(4, "big")
    if not a.yes:
        sys.exit("this WRITES the meter's settings; add --yes to do it")
    m.write_params(bytes(block))
    time.sleep(3)                     # the meter doesn't answer for a moment after a write
    back = bytearray(m.read_params())
    back[0x45:0x49] = block[0x45:0x49]     # the meter copies the setting time here itself
    if back == block:
        print("wrote %d bytes; read-back matches" % len(block))
    else:
        diffs = ["0x%02X: %02X->%02X" % (i, x, y) for i, (x, y) in enumerate(zip(block, back)) if x != y]
        print("wrote %d bytes; read-back DIFFERS at %s" % (len(block), ", ".join(diffs)))


def cmd_start(m, a):
    """Start a recording now: write the current settings with start mode Immediately."""
    block = bytearray(m.read_params())
    if a.total is not None:
        block[0x33:0x35] = a.total.to_bytes(2, "big")
    if a.interval is not None:
        if not 1 <= a.interval <= 60:
            sys.exit("interval must be 1..60 s")
        block[0x35] = a.interval
    block[0x44] = 1                                   # start mode: Immediately
    block[0x40:0x44] = local_epoch_seconds().to_bytes(4, "big")   # also sets the clock
    m.write_params(bytes(block))
    time.sleep(3)
    lv = m.live()
    print("recording %s: %d readings every %d s (count %d so far)"
          % ("started" if lv["u8@9"] else "NOT started", int.from_bytes(block[0x33:0x35], "big"),
             block[0x35], lv["u16@6"]))


def cmd_set_time(m, a):
    print("set time:", "OK" if m.set_time() else "not acknowledged")


def cmd_record(m, a):
    value = int(a.value, 16)
    print("record control %02X:" % value, "OK" if m.record_control(value) else "not acknowledged")


def cmd_raw(m, a):
    body = bytes.fromhex("".join(a.bytes))
    req, rsp = m.raw(body, a.reply_len)
    print("-> " + hexs(req))
    print("<- " + (hexs(rsp) or "(no reply)"))


def main():
    p = argparse.ArgumentParser(description="SLM-25 sound level meter tool (CH9326 USB-HID)")
    p.add_argument("--simulate", action="store_true", help="use a fake meter (no hardware)")
    p.add_argument("-v", "--verbose", action="store_true", help="show every packet")
    sub = p.add_subparsers(dest="command")
    sub.required = True

    sub.add_parser("identify", help="handshake (read-only)").set_defaults(func=cmd_identify)

    s = sub.add_parser("live", help="read the live reading (read-only)")
    s.add_argument("--repeat", type=int, default=1)
    s.add_argument("--interval", type=float, default=1.0, help="seconds between readings")
    s.add_argument("--raw", action="store_true", help="also show raw bytes and unknown fields")
    s.set_defaults(func=cmd_live)

    s = sub.add_parser("params", help="read the 81-byte parameter block (read-only)")
    s.add_argument("--second", action="store_true", help="read the settings and results of the current/last recording (cmd 06)")
    s.add_argument("--save", metavar="FILE", help="also save the raw block")
    s.set_defaults(func=cmd_params)

    s = sub.add_parser("download", help="download logged records (read-only)")
    s.add_argument("--start", type=int, default=0, help="first block number")
    s.add_argument("--blocks", type=int, default=1, help="number of blocks (13 records each)")
    s.add_argument("--csv", metavar="FILE", help="write CSV here instead of stdout")
    s.set_defaults(func=cmd_download)

    s = sub.add_parser("recording", help="the current recording with timestamps (read-only)")
    s.add_argument("--interval", type=float, default=None,
                   help="override seconds between readings (default: read from the meter)")
    s.add_argument("--csv", metavar="FILE", help="write CSV here instead of stdout")
    s.set_defaults(func=cmd_recording)

    s = sub.add_parser("write-params", help="WRITES: write an 81-byte parameter block "
                       "(e.g. from 'params --save') and verify it")
    s.add_argument("file", help="81-byte binary file")
    s.add_argument("--keep-time", action="store_true",
                   help="write 0x40 as-is instead of the current time; note the meter "
                   "sets its clock from this field")
    s.add_argument("--yes", action="store_true", help="required: confirm writing to the meter")
    s.set_defaults(func=cmd_write_params)

    s = sub.add_parser("start", help="WRITES: start a recording now (writes the settings "
                       "with start mode Immediately; erases the previous recording)")
    s.add_argument("--total", type=int, help="number of readings (default: keep current)")
    s.add_argument("--interval", type=int, help="seconds between readings, 1-60 (default: keep)")
    s.set_defaults(func=cmd_start)

    sub.add_parser("stop", help="WRITES: stop the running recording (03 40)"
                   ).set_defaults(func=lambda m, a: print("stop:", "OK" if m.record_control(0x40) else "not acknowledged"))

    sub.add_parser("set-time", help="WRITES: set the meter clock to this PC's local time"
                   ).set_defaults(func=cmd_set_time)

    s = sub.add_parser("record", help="WRITES: raw recording control (cmd 03); both 40 "
                       "and 00 stop a running recording (no difference seen)")
    s.add_argument("value", choices=["40", "00"])
    s.set_defaults(func=cmd_record)

    s = sub.add_parser("raw", help="send A5 <bytes> <sum> and print whatever comes back")
    s.add_argument("bytes", nargs="+", help="hex, e.g. 05 00")
    s.add_argument("--reply-len", type=int, help="stop after this many bytes")
    s.set_defaults(func=cmd_raw)

    a = p.parse_args()
    try:
        transport = SimulatedMeter() if a.simulate else CH9326Transport()
    except ProtocolError as e:
        sys.exit("error: %s" % e)
    try:
        a.func(SLM25(transport, verbose=a.verbose), a)
    except ProtocolError as e:
        sys.exit("error: %s" % e)
    finally:
        transport.close()


if __name__ == "__main__":
    main()
