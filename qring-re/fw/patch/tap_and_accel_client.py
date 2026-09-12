#!/usr/bin/env python3
"""Host/phone-side client for the RT12 accel+tap patch.

- Polls the new firmware command 0xB2 for the latest accelerometer sample.
- Derives single / double / triple tap from the EXISTING single-tap event the
  stock firmware already sends (0x73 notify, subtype 45, value 3) -- so taps
  work even without the firmware patch; only the accel stream needs 0xB2.

Transport is intentionally abstracted: plug in your BLE stack by implementing
`write_cmd(16 bytes)` on the command characteristic (6E400002) and feeding every
16-byte command-notify frame (6E400003) into `Ring.on_notify(frame)`. GATT UUIDs
are in ../notes/sdk-protocol.md.
"""
import time, struct

CMD_ACCEL   = 0xB2          # added by the firmware patch
CMD_NOTIFY  = 0x73          # stock device-notify
TAP_SUBTYPE = 45            # stock "gesture" subtype; value 3 == single click
TAP_WINDOW  = 0.40          # seconds; two clicks within this -> double, a third -> triple


def checksum(frame15: bytes) -> int:
    return sum(frame15) & 0xFF


def build_cmd(cmd: int, payload: bytes = b"") -> bytes:
    body = bytes([cmd]) + payload.ljust(14, b"\x00")[:14]
    return body + bytes([checksum(body)])


class Ring:
    def __init__(self, write_cmd, on_accel=None, on_tap=None):
        self.write_cmd = write_cmd          # callable(bytes[16]) -> None
        self.on_accel = on_accel            # callable(x, y, z)
        self.on_tap = on_tap                # callable(count in {1,2,3})
        self._taps = []                     # timestamps of recent single-tap events

    # ---- accelerometer -----------------------------------------------------
    def poll_accel(self):
        """Request one accelerometer sample; the reply arrives in on_notify."""
        self.write_cmd(build_cmd(CMD_ACCEL))

    def stream_accel(self, hz=25, seconds=None):
        """Blocking poll loop. Your BLE stack must pump notifications concurrently."""
        period = 1.0 / hz
        t_end = None if seconds is None else time.time() + seconds
        while t_end is None or time.time() < t_end:
            self.poll_accel()
            time.sleep(period)

    # ---- notification sink -------------------------------------------------
    def on_notify(self, frame: bytes):
        """Feed every 16-byte command-notify frame here."""
        if len(frame) != 16 or checksum(frame[:15]) != frame[15]:
            return
        # NOTE: 0xB2 has bit 7 set, which the BLE framing normally uses as the
        # error-flag bit. The accel reply carries the raw byte 0xB2 (not an error),
        # so match it directly and do NOT mask; only mask for real command ids.
        if frame[0] == CMD_ACCEL:
            x, y, z = struct.unpack_from("<hhh", frame, 1)
            if self.on_accel:
                self.on_accel(x, y, z)
        elif (frame[0] & 0x7F) == CMD_NOTIFY and frame[1] == TAP_SUBTYPE and frame[2] == 3:
            self._register_tap()

    # ---- tap counting ------------------------------------------------------
    def _register_tap(self):
        now = time.time()
        self._taps = [t for t in self._taps if now - t <= TAP_WINDOW]
        self._taps.append(now)
        # Emit on a settle: schedule a check TAP_WINDOW after the last tap.
        # In an event loop, call flush_taps() from a timer; here we expose it.

    def flush_taps(self):
        """Call ~TAP_WINDOW after the last tap (e.g. from a timer) to emit 1/2/3."""
        if not self._taps:
            return
        if time.time() - self._taps[-1] < TAP_WINDOW:
            return                       # still within a burst, wait
        count = min(len(self._taps), 3)
        self._taps.clear()
        if self.on_tap:
            self.on_tap(count)


if __name__ == "__main__":
    # Demo with a fake transport so the logic is runnable without a ring.
    log = []
    ring = Ring(write_cmd=lambda f: log.append(f),
                on_accel=lambda x, y, z: print(f"accel  x={x:6d} y={y:6d} z={z:6d}"),
                on_tap=lambda n: print(f"tap    {['','single','double','triple'][n]}"))
    # accel reply: 0xB2, x=100, y=-200, z=16000
    ring.on_notify(build_cmd(0xB2, struct.pack("<hhh", 100, -200, 16000)))
    # three quick single-tap events -> triple
    for _ in range(3):
        ring.on_notify(build_cmd(0x73, bytes([45, 3])))
    time.sleep(TAP_WINDOW + 0.05)
    ring.flush_taps()
