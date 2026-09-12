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
| `ota_flash.py` | **firmware uploader** — pushes an image over the ring's own BLE updater (ports the app's `DfuHandle`). Dry-run by default; `--flash --address <MAC>` to upload. |
| `sim_accel_patch.py` | **emulator harness** (Unicorn): runs the real patched bytes; proves decode, passthrough for all 255 other commands, the 0x5A reply for every FIFO head, and clean-vs-patched call traces. `pip install unicorn capstone && python3 sim_accel_patch.py` |

Rebuild: `python3 build_patch.py`.

## What the firmware patch does

The dispatcher `ble_cmd_dispatch` (0x82b626) is entered with `r0` = the 16-byte command
packet. Its first two instructions (`push {r4,lr}; mov r4,r0`, 4 bytes) are replaced with a
`b.w` into a 54-byte routine placed in the tail code-cave at `0x847840` (298 free zero bytes
inside the mapped image). The routine:

1. reads `packet[0]`; if it is **not** `0x5A`, it replays the two displaced instructions and
   branches back to `0x82b62a`, so every existing command behaves exactly as before;
2. if it **is** `0x5A`, it takes the most recent sample from the accelerometer FIFO ring
   (`accel_fifo_ring` at `0x20bdf8`, head at `0x20bdf4`, interleaved `x,y,z` int16 LE, stride
   6, size 0x1ec) and calls `send_reply_payload(0x5A, &sample, 6)`.

It is **stateless** and touches no other code path — the lowest-risk shape I could give it.

### Wire protocol added

```
phone -> ring   16-byte frame, byte[0] = 0x5A                 (poll; bytes 1..14 ignored)
ring  -> phone  16-byte frame, byte[0] = 0x5A, [1..2]=x, [3..4]=y, [5..6]=z  (int16 LE)
                                              byte[15] = checksum (sum of bytes 0..14)
```

Poll as fast as you like; each reply is the newest sample the sensor wrote (25 Hz ODR on the
LIS3DH-style path, so ~40 ms is the useful floor). This is "streaming by polling"; it needs no
new device-initiated notify and no new RAM state, which is why it is safe to add.

Command id: `0x5A`. The emulator enumerated every id the stock firmware answers with
`reply_unsupported` (175 of them) and intersected that with the ids the phone app uses; `0x5A`
sits in a block of thirteen ids (`0x53..0x5E`) free on both sides. An earlier draft used `0xB2`,
which was rejected because bit 7 is the framing's error flag: `0xB2` is indistinguishable from
an error reply to command `0x32`, which the app's table lists. To change the id, edit the two
immediates in `build_patch.py` (`0x295A`, `0x205A`), `accel_stream.s`, `CMD_ACCEL` in the
client and `CMD` in the harness, then rebuild and rerun the harness.

## Taps: single / double / triple

The firmware **already** reports a single tap: the sensor's click interrupt is emitted to the
phone as the unsolicited `0x73` notification, subtype **45**, value **3** (see
`../notes/app-layer.md` §4.2 and `send_device_notify`). Double and triple tap are **not** in
firmware and the LIS3DH-style sensor on this ring only does single-click in hardware.

`tap_and_accel_client.py` derives them on the host by counting those existing single-tap
events inside a time window (<=400 ms apart -> double, a third <=400 ms -> triple). This needs
no firmware change and carries zero brick risk, so it is the recommended path for taps. The
accel `0x5A` command is the only part that genuinely required a firmware change.

If you truly want the ring itself to emit a 1/2/3 tap code, that is a second hook on the
tap-emit path plus an OS timer for the inter-tap window; I left it out of this image on
purpose because it modifies a live interrupt path (higher risk) and the host-side counter is
equivalent. Ask and I will write that hook as a separate, clearly-marked patch.

## Deploying to the ring (BLE OTA)

The ring flashes **itself** over BLE — no soldering, no UART for the normal path. The app class
`com.oudmon.ble.base.communication.DfuHandle` drives it on the big-data service `de5bf728`
(write `de5bf72a`, notify `de5bf729`). Frames are `[0xBC][cmd][len u16 LE][crc16-MODBUS u16 LE][payload]`,
split into MTU writes; the sequence is: `cmd1` start, `cmd2` init `[01][len u32][crc16 u16][bytesum u16]`,
`cmd3` data `[seq u16][<=1024 B]` repeated, `cmd4` check, `cmd5` end.

`ota_flash.py` reproduces that exactly. It is a **dry run** unless you pass `--flash`:

```
python3 ota_flash.py                           # build + verify frames for the patched image
python3 ota_flash.py --flash --address <MAC>   # real upload over BLE
python3 ota_flash.py --file ../base_RT12_3.10.06_260429.bin --flash --address <MAC>   # roll back
```

The stock QRing app will NOT flash a local file (it only installs server-downloaded, version-gated
images), which is why the uploader drives the protocol directly.

### Why this is fail-safe (from the firmware receiver)
- The image is received into **spare flash at 0x84e000**, never over the running app at 0x826000.
- Every `0xBC` frame is CRC-16/MODBUS checked before use (`bigdata_rx_complete`); a bad frame is NAK'd.
- The first chunk is gated on the wrapper magic `0x81BDC3E5` at offset 0 and a `memcmp` of the
  `"RT12_V3.1"` model string (`algo_fn_83db3c`) — no signature, no crypto.
- Commit (mark the new image valid + reboot, `boot_log_826f2a(&0x2793)`) happens **only** after the
  received length matches the announced length. A failed or interrupted transfer leaves the running
  image bootable.
- The patch never touches the boot or OTA-receiver code, so the new image can always OTA back to
  stock. That is the rollback path; keep `../base_RT12_3.10.06_260429.bin`.

## SAFETY — read before flashing anything

### What is now verified (software)
- `sim_accel_patch.py` executes the patched image on an emulated Cortex-M core. All checks pass:
  the hook and cave decode exactly as `accel_stream.s`; the real `send_reply_payload` ->
  `checksum_u8` path runs and the 16-byte frame captured at `tx_enqueue_packet` parses correctly
  in `tap_and_accel_client.py` (`--deep`); for every command byte except 0x5A the
  machine state at `ble_cmd_dispatch+4` is identical to the clean firmware (r0, r2-r7, sp, lr,
  pushed words; only the dead register r1 differs); 0x5A calls `send_reply_payload(0x5A, &newest, 6)`
  for all 83 FIFO head positions including the wrap, and returns to the caller with sp balanced and
  r4 restored; clean-vs-patched callee traces are identical for the other 255 commands.
- The index math (`head-6`, wrap `+0x1ec` after the borrow) equals the firmware's own
  `gsensor_read_recent` (`head + 0x1e6`).
- The cave at 0x847840 sits in a 298-byte zero run between a const table and the
  `lib_BIODetect_V14_1` string; nothing in the image references that range.
- The Realtek image header (file 0x50..0x450) is untouched. Decoded from the stock image:
  `ctrl_flag = 0x0981` → `integrity_check_en_in_boot = 0`, `crc16 = 0`, `sha256` all zero.
  The boot ROM is not checksumming the app payload (the stock image would fail if it were), so the
  open question from the earlier handoff is resolved: there is no hidden boot integrity field to
  satisfy. `build_patch.py` recomputes the only live checksum, the vendor wrapper's byte-sum at 0x0C (a sum over file[0x50:], i.e. the Realtek image; an earlier draft of build_patch.py summed from 0x10 and was corrected).
- The app image contains no OTA receiver, so updates are handled below it (Realtek ROM/stack,
  dual-bank `not_ready` / `not_obsolete` header flags). The patch changes nothing in that header.

- The harness also caught a real regression during the id change (a commented-out `movs r2,#6`
  shrank the cave to 52 bytes); rebuilt and re-verified at 54 bytes.

### What is NOT verified
- It has never run on a ring. The emulator models the CPU, SRAM and the reply call; it does not
  model the BLE stack, timing, or the ROM DFU's acceptance rules (no ROM dump is available).
- Torn reads: the BLE task reads `head` and 6 bytes while the app task may be writing the ring.
  Worst case is one mixed-axis sample, never a fault.
- While gesture detection is armed the firmware's own reader drains the chip FIFO before reading;
  the hook does not, so its sample can lag by one FIFO drain. Still a valid sample.

### Recovery
- No QEMU/Renode model of the RTL8762 exists; the harness above is the simulator.
- A rejected or crashing image is recoverable over UART with `rtltool` (RTS = reset, DTR low =
  flash mode, uploads `firmware0.bin` from the BeeMPTool kit, arbitrary flash read/write/erase
  from 0x00800000). The ring is a sealed 5ATM unit, so that path needs opening the case.
- Because the hook only runs when a BLE command arrives and the boot path is untouched, a bug in
  the 0x5A handler would at worst reset the ring, leaving the stock OTA route available to go back
  to `../base_RT12_3.10.06_260429.bin`.
- Still: first flash on a **sacrificial unit**, never your only ring, and never blindly.
