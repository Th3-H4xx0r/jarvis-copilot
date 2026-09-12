#!/usr/bin/env python3
"""Push a firmware image to the R12 ring over its OWN BLE updater (no app, no soldering).

This is a faithful port of the phone app's OTA driver
(com.oudmon.ble.base.communication.DfuHandle): the same big-data service, the same
0xBC frame format, the same cmd sequence. The ring stages the image in spare flash
and only commits after its own checks, so a failed/aborted transfer leaves the
running firmware intact (see README "SAFETY").

DRY RUN by default: builds and verifies every frame, checks the file against the
firmware receiver's preconditions, and prints what WOULD be sent. It does not touch
Bluetooth. Add --flash (and `pip install bleak`) to actually connect and upload.

  python3 ota_flash.py                      # dry run on the patched image
  python3 ota_flash.py --file ../base_RT12_3.10.06_260429.bin   # dry run: roll back to stock
  python3 ota_flash.py --flash --address <MAC>                  # REAL upload
"""
import os, sys, struct, argparse

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_FILE = os.path.join(HERE, 'base_RT12_3.11.00_260911.bin')

# GATT (DfuHandle.SERIAL_PORT_*) — the big-data channel the firmware's 0xBC receiver listens on
SVC   = 'de5bf728-d711-4e47-af26-65e3012a5dc7'
WRITE = 'de5bf72a-d711-4e47-af26-65e3012a5dc7'
NOTIFY= 'de5bf729-d711-4e47-af26-65e3012a5dc7'

POCKET = 1024          # DfuHandle "big pocket" data bytes per cmd-3 frame
MAGIC  = 0x81BDC3E5    # wrapper magic the receiver checks at offset 0 (ble_tx_fn_82e242)
MODEL  = b'RT12_V3.1'  # model string the receiver memcmps on the first chunk

def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc & 0xFFFF

def bc_frame(cmd: int, payload: bytes = b'') -> bytes:
    """DfuHandle.addHeader: [0xBC][cmd][len u16 LE][crc16 u16 LE][payload]; empty -> len0, crc FFFF."""
    if not payload:
        return bytes([0xBC, cmd, 0, 0, 0xFF, 0xFF])
    return bytes([0xBC, cmd]) + struct.pack('<HH', len(payload), crc16_modbus(payload)) + payload

def byte_sum16(data: bytes) -> int:
    return sum(data) & 0xFFFF

def build_session(image: bytes):
    """Return the ordered list of (label, 0xBC frame) the app would send for this image."""
    crc = crc16_modbus(image)
    chk = byte_sum16(image)
    frames = [('start',  bc_frame(1)),
              ('init',   bc_frame(2, b'\x01' + struct.pack('<IHH', len(image), crc, chk)))]
    idx = 0
    while idx * POCKET < len(image):
        pocket = image[idx * POCKET: idx * POCKET + POCKET]
        frames.append((f'data[{idx}]', bc_frame(3, struct.pack('<H', idx + 1) + pocket)))
        idx += 1
    frames += [('check', bc_frame(4)), ('end', bc_frame(5))]
    return frames, crc, chk, idx

def check_preconditions(image: bytes):
    """The gates the firmware receiver applies before it will commit (from the decompile)."""
    n = len(image)
    out = []
    magic = struct.unpack_from('<I', image, 0)[0]
    out.append((magic == MAGIC, f'wrapper magic @0 = {magic:#010x} (want {MAGIC:#010x})'))
    out.append((0x2800 <= n < 0x24051, f'size {n:#x} in receiver range [0x2800,0x24051)'))
    out.append((MODEL in image[:0x200], f'model string {MODEL!r} present near header'))
    img_id = struct.unpack_from('<H', image, 0x54)[0]
    out.append((img_id == 0x2793, f'image_id @0x54 = {img_id:#06x} (want 0x2793)'))
    wrap_sum = struct.unpack_from('<I', image, 0xc)[0]
    out.append((wrap_sum == sum(image[0x50:]) & 0xffffffff, 'wrapper byte-sum @0x0C self-consistent (sum over file[0x50:])'))
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', default=DEFAULT_FILE)
    ap.add_argument('--flash', action='store_true', help='actually connect over BLE and upload')
    ap.add_argument('--address', help='ring BLE MAC/UUID (required with --flash)')
    args = ap.parse_args()

    image = open(args.file, 'rb').read()
    frames, crc, chk, npockets = build_session(image)
    total_bytes = sum(len(f) for _, f in frames)

    print(f'image      : {os.path.basename(args.file)}  ({len(image)} bytes)')
    print(f'whole-image: crc16-modbus={crc:#06x}  byte-sum16={chk:#06x}')
    print(f'session    : {len(frames)} frames ({npockets} data pockets), {total_bytes} bytes on the wire')
    print('preconditions (firmware receiver gates):')
    ok_all = True
    for ok, msg in check_preconditions(image):
        print(f'  [{"OK" if ok else "FAIL"}] {msg}'); ok_all &= ok
    for label, f in frames:  # every frame re-CRCs like the ring's bigdata_rx_complete will
        if len(f) > 6:
            assert crc16_modbus(f[6:]) == struct.unpack_from('<H', f, 4)[0], f'frame {label} crc mismatch'
    print('frame CRCs : all self-consistent (the ring CRC-checks every frame before use)')
    for label in ('start', 'init', 'check', 'end'):
        print(f'  {label:5}: {dict(frames)[label].hex()}')
    d0 = dict(frames)['data[0]']
    print(f'  data[0]: {d0[:12].hex()}... ({len(d0)} bytes)')

    if not ok_all:
        print('\nPRECONDITIONS FAILED — the ring would reject this image. Not safe to flash.'); sys.exit(1)
    if not args.flash:
        print('\nDRY RUN ok. Re-run with --flash --address <MAC> to upload for real.')
        return
    if not args.address:
        print('ERROR: --flash needs --address <ring MAC/UUID>'); sys.exit(2)
    import asyncio
    asyncio.run(flash(args.address, frames))

async def flash(address, frames):
    import asyncio
    from bleak import BleakClient  # lazy: only needed for a real flash
    done = asyncio.Event(); state = {'seq': 0, 'err': None, 'sent': 0}
    data_frames = [f for l, f in frames if l.startswith('data[')]
    bylabel = dict(frames)

    print(f'\nConnecting to {address} ...')
    async with BleakClient(address) as client:
        mtu = getattr(client, 'mtu_size', 23) or 23
        chunk = mtu - 3

        async def send_frame(frame):
            for i in range(0, len(frame), chunk):
                await client.write_gatt_char(WRITE, frame[i:i + chunk], response=False)
                await asyncio.sleep(0.01)

        def on_notify(_, data: bytearray):
            data = bytes(data)
            if len(data) < 7 or data[0] != 0xBC:
                return
            cmd, status = data[1], data[6]
            if status != 0:
                state['err'] = f'ring rejected cmd {cmd} with status {status}'; done.set(); return
            loop = asyncio.get_event_loop()
            if cmd == 1:
                loop.create_task(send_frame(bylabel['init']))
            elif cmd == 2:
                loop.create_task(send_frame(data_frames[0])); state['seq'] = 1
            elif cmd == 3:
                state['sent'] += 1
                if state['seq'] < len(data_frames):
                    loop.create_task(send_frame(data_frames[state['seq']])); state['seq'] += 1
                else:
                    loop.create_task(send_frame(bylabel['check']))
                if state['sent'] % 16 == 0:
                    print(f'  uploaded {state["sent"]}/{len(data_frames)} pockets')
            elif cmd == 4:
                loop.create_task(send_frame(bylabel['end']))
            elif cmd == 5:
                done.set()

        await client.start_notify(NOTIFY, on_notify)
        await send_frame(bylabel['start'])
        try:
            await asyncio.wait_for(done.wait(), timeout=300)
        except asyncio.TimeoutError:
            state['err'] = 'timeout'
    if state['err']:
        print(f'FAILED: {state["err"]}  (the ring keeps running the OLD image; retry is safe)'); sys.exit(3)
    print('Upload + commit acknowledged. The ring will reboot into the new image.')

if __name__ == '__main__':
    main()
