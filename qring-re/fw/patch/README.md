# RT12 firmware patch — expose accelerometer + taps over BLE

Adds live accelerometer readout to the ring firmware and gives the phone single / double /
triple tap. This is a **byte patch of the app image**, built here as source + a reproducible
script. **Nothing here flashes the ring.** See the safety section before you ever do.

## Files

| File | What |
|---|---|
| `accel_stream.s` | the hook, as commented ARM Thumb-2 assembly (the source of truth) |
| `build_patch.py` | rebuilds the patched image from the clean base; encodes + verifies every branch |
| `base_RT12_3.11.00_260911.bin` | the patched image (version bumped from 3.10.06_260429), 80 bytes changed |
| `tap_and_accel_client.py` | **phone/host side** — poll accel + derive single/double/triple tap. Works today, no flashing. |

Rebuild: `python3 build_patch.py`.

## What the firmware patch does

The dispatcher `ble_cmd_dispatch` (0x82b626) is entered with `r0` = the 16-byte command
packet. Its first two instructions (`push {r4,lr}; mov r4,r0`, 4 bytes) are replaced with a
`b.w` into a 54-byte routine placed in the tail code-cave at `0x847840` (298 free zero bytes
inside the mapped image). The routine:

1. reads `packet[0]`; if it is **not** `0xB2`, it replays the two displaced instructions and
   branches back to `0x82b62a`, so every existing command behaves exactly as before;
2. if it **is** `0xB2`, it takes the most recent sample from the accelerometer FIFO ring
   (`accel_fifo_ring` at `0x20bdf8`, head at `0x20bdf4`, interleaved `x,y,z` int16 LE, stride
   6, size 0x1ec) and calls `send_reply_payload(0xB2, &sample, 6)`.

It is **stateless** and touches no other code path — the lowest-risk shape I could give it.

### Wire protocol added

```
phone -> ring   16-byte frame, byte[0] = 0xB2                 (poll; bytes 1..14 ignored)
ring  -> phone  16-byte frame, byte[0] = 0xB2, [1..2]=x, [3..4]=y, [5..6]=z  (int16 LE)
                                              byte[15] = checksum (sum of bytes 0..14)
```

Poll as fast as you like; each reply is the newest sample the sensor wrote (25 Hz ODR on the
LIS3DH-style path, so ~40 ms is the useful floor). This is "streaming by polling"; it needs no
new device-initiated notify and no new RAM state, which is why it is safe to add.

Note: `0xB2` has bit 7 set, which the 16-byte framing normally uses as its error-flag bit. The
dispatcher matches the full byte so the command works, but the **reply** also carries the raw
byte `0xB2` — the host must match it directly (do not mask off bit 7). `tap_and_accel_client.py`
does this. If you prefer a clean low command id, change `CMD_ACCEL` in both the patch and the
client to any unused id < 0x80.

## Taps: single / double / triple

The firmware **already** reports a single tap: the sensor's click interrupt is emitted to the
phone as the unsolicited `0x73` notification, subtype **45**, value **3** (see
`../notes/app-layer.md` §4.2 and `send_device_notify`). Double and triple tap are **not** in
firmware and the LIS3DH-style sensor on this ring only does single-click in hardware.

`tap_and_accel_client.py` derives them on the host by counting those existing single-tap
events inside a time window (<=400 ms apart -> double, a third <=400 ms -> triple). This needs
no firmware change and carries zero brick risk, so it is the recommended path for taps. The
accel `0xB2` command is the only part that genuinely required a firmware change.

If you truly want the ring itself to emit a 1/2/3 tap code, that is a second hook on the
tap-emit path plus an OS timer for the inter-tap window; I left it out of this image on
purpose because it modifies a live interrupt path (higher risk) and the host-side counter is
equivalent. Ask and I will write that hook as a separate, clearly-marked patch.

## SAFETY — read before flashing anything

- This image is **unverified on hardware.** The Thumb code and all four branch targets are
  decode-checked, and `build_patch.py` reproduces the bytes deterministically, but it has
  **not** run on a ring.
- `build_patch.py` recomputes the **byte-sum word at offset 0x0C** (the one integrity field I
  confirmed earlier). It does **not** touch the 32-bit word at offset 0x00 or prove out the
  Realtek image-header integrity field, because the exact boot-checked field was not fully
  reverse-engineered. **Confirm that before flashing**, or the boot ROM may reject the image.
- The ring is a sealed 5ATM device with **no non-destructive recovery** if the bootloader
  rejects a patched image. Only flash a **sacrificial unit** first, over a recoverable path
  (UART / rtltool), never your only ring, never blindly via the OTA app.
