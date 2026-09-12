#!/usr/bin/env python3
"""Emulator harness for the RT12 accel+tap firmware patch.

No RTL8762 model exists in QEMU or Renode, so this runs the REAL patched image
bytes on a Cortex-M (Thumb-2) CPU via Unicorn, with the two things the hook
touches modelled: SRAM (the accel FIFO ring) and the reply path.

What it proves, on the exact bytes in base_RT12_3.11.00_260911.bin:
  1. decode   - the 4 patched bytes at ble_cmd_dispatch and the 54-byte cave
                disassemble to exactly the instructions in accel_stream.s, and
                nothing else changed except version digits + the 0x0C sum.
  2. passthru - for every command byte except 0x5A, the cave hands control to
                ble_cmd_dispatch+4 with machine state IDENTICAL to the clean
                firmware at the same point (r0, r4, lr, sp, pushed words).
  3. accel    - for 0x5A the cave calls send_reply_payload(0x5A, &sample, 6)
                where the 6 bytes are the newest FIFO sample, for every head
                position (0..486 step 6, plus 0x1ec), then returns to the
                dispatcher's caller with r4 restored and sp balanced.
  4. trace    - differential: clean vs patched image run from the real
                dispatcher entry for all 256 command bytes with every callee
                stubbed+logged. Call traces must be identical except 0x5A
                (clean -> reply_unsupported, patched -> send_reply_payload).

Run:  python3 sim_accel_patch.py      (needs: pip install unicorn capstone)
"""
import os, struct
from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_MODE_MCLASS, UC_HOOK_BLOCK, UC_HOOK_CODE, UcError
from unicorn.arm_const import *
from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_MCLASS

HERE = os.path.dirname(os.path.abspath(__file__))
CLEAN = os.path.join(HERE, '..', 'base_RT12_3.10.06_260429.bin')
PATCHED = os.path.join(HERE, 'base_RT12_3.11.00_260911.bin')

VBASE = 0x825fb0                  # vaddr = file_offset + VBASE
DISP = 0x82b626; DISP_END = 0x82b9b6; CONT = 0x82b62a
CAVE = 0x847840; CAVE_END = 0x847880
SWITCH8 = 0x84027c; SWITCH8_END = 0x8402a0
SEND_REPLY = 0x82a616; REPLY_UNSUP = 0x82a98e; QUEUE_CMD = 0x82ab6c; MARK_ACT = 0x82dea2
HEAD = 0x20bdf4; RINGB = 0x20bdf8; RSIZE = 0x1ec
CMD = 0x5a                        # the accel command id (must match build_patch.py / accel_stream.s)
SENTINEL = 0x0ffffff0             # fake return address for the dispatcher's caller

NAMES = {SEND_REPLY: 'send_reply_payload', REPLY_UNSUP: 'reply_unsupported',
         QUEUE_CMD: 'queue_cmd_for_task', MARK_ACT: 'ble_rx_mark_activity'}

FLASH_LO = 0x825000; FLASH_SZ = 0x24000       # covers 0x825fb0..0x847a94
SRAM_LO = 0x200000; SRAM_SZ = 0x10000          # covers 0x20bdf4.. (FIFO) + scratch
STACK_TOP = 0x20f000
PKT = 0x20e000                                 # fake 16-byte command packet in SRAM
SENT_LO = SENTINEL & ~0xfff
R4_IN = 0x44444444

def make_uc(image):
    uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS)
    uc.mem_map(FLASH_LO, FLASH_SZ)
    uc.mem_map(SRAM_LO, SRAM_SZ)
    uc.mem_map(SENT_LO, 0x1000)
    uc.mem_write(VBASE, image)
    uc.mem_write(SENTINEL, b'\x00\xbf' * 4)   # nops at the sentinel
    return uc

def seed_fifo(uc, head):
    """Fill the 82-slot ring with distinct int16 triples: slot i -> (i, -i, 1000+i)."""
    ring = b''.join(struct.pack('<hhh', i, -i, 1000 + i) for i in range(RSIZE // 6))
    assert len(ring) == RSIZE
    uc.mem_write(RINGB, ring)
    uc.mem_write(HEAD, struct.pack('<H', head))
    uc.mem_write(HEAD + 2, struct.pack('<H', 0))   # accel_fifo_tail
    return ring

def newest_sample(ring, head):
    off = head - 6
    if off < 0: off += RSIZE       # the firmware's own gsensor_read_recent idiom (head + 0x1e6)
    return ring[off:off + 6]

REGS = (('r0', UC_ARM_REG_R0), ('r1', UC_ARM_REG_R1), ('r2', UC_ARM_REG_R2), ('r3', UC_ARM_REG_R3),
        ('r4', UC_ARM_REG_R4), ('r5', UC_ARM_REG_R5), ('r6', UC_ARM_REG_R6), ('r7', UC_ARM_REG_R7),
        ('sp', UC_ARM_REG_SP), ('lr', UC_ARM_REG_LR), ('pc', UC_ARM_REG_PC))

def regs(uc):
    return {n: uc.reg_read(r) for n, r in REGS}

def setup_call(uc, cmd):
    """Machine state as ble_cmd_char_write_cb leaves it right before the dispatcher's first instruction."""
    pkt = bytes([cmd]) + bytes(range(0x11, 0x1f)) + b'\x00'
    uc.mem_write(PKT, pkt)
    uc.mem_write(STACK_TOP - 0x100, b'\xcc' * 0x100)   # poison stack so pushed words are visible
    for r, v in ((UC_ARM_REG_R0, PKT), (UC_ARM_REG_R1, 0x10), (UC_ARM_REG_R2, 0xa2a2a2a2), (UC_ARM_REG_R3, 0xa3a3a3a3),
                 (UC_ARM_REG_R4, R4_IN), (UC_ARM_REG_R5, 0x55555555), (UC_ARM_REG_R6, 0x66666666),
                 (UC_ARM_REG_R7, 0x77777777), (UC_ARM_REG_SP, STACK_TOP), (UC_ARM_REG_LR, SENTINEL | 1)):
        uc.reg_write(r, v)

def trash_caller_saved(uc):
    for x in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3):
        uc.reg_write(x, 0xbadbad00)

# ---------------------------------------------------------------- 1. decode
def test_decode(patched, clean):
    print('== 1. decode: patched bytes disassemble to the intended hook ==')
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB | CS_MODE_MCLASS)
    fo = lambda v: v - VBASE
    out = []
    for a, b in ((DISP, DISP + 4), (CAVE, CAVE + 54)):
        for ins in md.disasm(patched[fo(a):fo(b)], a):
            out.append(f'  {ins.address:08x}: {ins.bytes.hex():<10} {ins.mnemonic:<6} {ins.op_str}')
    txt = '\n'.join(out)
    print(txt)
    expect = ['b.w    #0x847840', 'ldrb   r1, [r0]', f'cmp    r1, #{CMD:#x}', 'beq    #0x84784e', 'push   {r4, lr}',
              'mov    r4, r0', 'b.w    #0x82b62a', 'movw   r3, #0xbdf4', 'movt   r3, #0x20', 'ldrh   r2, [r3]',
              'subs   r2, #6', 'bpl    #0x847862', 'addw   r2, r2, #0x1ec', 'movw   r1, #0xbdf8', 'movt   r1, #0x20',
              'add    r1, r2', f'movs   r0, #{CMD:#x}', 'movs   r2, #6', 'bl     #0x82a616', 'pop    {r4, pc}']
    expect = [e.replace('{CMD}', f'{CMD:#x}') for e in expect]
    missing = [e for e in expect if e not in txt]
    assert not missing, f'unexpected decode, missing: {missing}'
    diffs = [i for i in range(len(clean)) if clean[i] != patched[i]]
    allowed = set(range(0xc, 0x10)) | set(range(fo(DISP), fo(DISP) + 4)) | set(range(fo(CAVE), fo(CAVE) + 54))
    others = [i for i in diffs if i not in allowed]
    for i in others:
        assert clean[i:i+1] in b'0123456789' and patched[i:i+1] in b'0123456789', f'non-version diff at {i:#x}'
    assert all(clean[fo(CAVE) + k] == 0 for k in range(54)), 'cave not zero in the clean image'
    assert not any(0x50 <= i < 0x450 for i in diffs), 'Realtek image header modified!'
    assert struct.unpack_from('<I', patched, 0xc)[0] == sum(patched[0x50:]) & 0xffffffff, 'wrapper sum wrong'
    print(f'  {len(diffs)} bytes differ: 4 hook + 54 cave + {len(others)} version-string digits + 0x0C sum; '
          f'Realtek header 0x50..0x450 untouched; cave was all-zero.  OK')

# ---------------------------------------------------------------- 2. passthru
def run_to(uc, start, stop_pcs, max_insns=200):
    hit = {}
    def hook(uc, addr, size, ud):
        if addr in stop_pcs:
            hit['pc'] = addr; uc.emu_stop()
    h = uc.hook_add(UC_HOOK_CODE, hook)
    try:
        uc.emu_start(start | 1, 0, count=max_insns)
    except UcError as e:
        hit['err'] = str(e)
    uc.hook_del(h)
    return hit

def state_at_cont(image, cmd):
    uc = make_uc(image); seed_fifo(uc, 0x30); setup_call(uc, cmd)
    hit = run_to(uc, DISP, {CONT, SEND_REPLY, SENTINEL})
    r = regs(uc)
    r['stack'] = uc.mem_read(STACK_TOP - 8, 8).hex()
    return hit, r

def test_passthru(patched, clean):
    print('== 2. passthru: every cmd != 0x5A reaches dispatch+4 in the clean machine state ==')
    bad = []
    for cmd in range(256):
        if cmd == CMD: continue
        hc, rc = state_at_cont(clean, cmd)
        hp, rp = state_at_cont(patched, cmd)
        assert hc.get('pc') == CONT and hp.get('pc') == CONT, (cmd, hc, hp)
        # r1 is clobbered by the cave (ldrb r1,[r0]); it is dead here (not an input). Everything else must match.
        keys = ['r0', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7', 'sp', 'lr', 'pc', 'stack']
        d = {k: (rc[k], rp[k]) for k in keys if rc[k] != rp[k]}
        if d: bad.append((cmd, d))
        assert rp['r4'] == PKT and rp['sp'] == STACK_TOP - 8 and rp['lr'] == SENTINEL | 1
        assert struct.unpack('<II', bytes.fromhex(rp['stack'])) == (R4_IN, SENTINEL | 1)
    assert not bad, bad
    print('  255/255 command bytes: r0,r2-r7,sp,lr and the pushed {r4,lr} identical to clean firmware at 0x82b62a.  OK')
    print('  (r1 differs by design: cave loads packet[0] into r1; r1 is not an input of ble_cmd_dispatch.)')

# ---------------------------------------------------------------- 3. accel
def test_accel(patched):
    print('== 3. accel: 0x5A replies the newest FIFO sample for every head position ==')
    heads = list(range(0, RSIZE, 6)) + [RSIZE]
    for head in heads:
        uc = make_uc(patched); ring = seed_fifo(uc, head); setup_call(uc, CMD)
        calls = []
        def hook(uc, addr, size, ud):
            if addr == SEND_REPLY:
                r0, r1, r2 = (uc.reg_read(x) for x in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2))
                calls.append((r0, r1, r2, bytes(uc.mem_read(r1, r2))))
                trash_caller_saved(uc)                      # behave like a real callee (r4 is callee-saved, kept)
                uc.reg_write(UC_ARM_REG_PC, uc.reg_read(UC_ARM_REG_LR))
            elif addr == SENTINEL:
                uc.emu_stop()
        uc.hook_add(UC_HOOK_CODE, hook)
        uc.emu_start(DISP | 1, 0, count=400)
        r = regs(uc)
        assert len(calls) == 1, (head, calls)
        r0, r1, r2, data = calls[0]
        exp = newest_sample(ring, head)
        assert r0 == CMD and r2 == 6, (head, hex(r0), r2)
        assert data == exp, (head, data.hex(), exp.hex())
        assert r1 == RINGB + ((head - 6) % RSIZE), (head, hex(r1))
        assert r['pc'] == SENTINEL and r['sp'] == STACK_TOP and r['r4'] == R4_IN, (head, r)
    x, y, z = struct.unpack('<hhh', newest_sample(seed_fifo(make_uc(patched), 0), 0))
    print(f'  {len(heads)} head values incl. 0 (wrap -> slot 81 = ({x},{y},{z})) and 0x1ec: '
          f'send_reply_payload(0x5A, &newest, 6) then return to caller, sp balanced, r4 restored.  OK')

# ---------------------------------------------------------------- 4. trace
def trace(image, cmd):
    uc = make_uc(image); seed_fifo(uc, 0x30); setup_call(uc, cmd)
    log = []
    def inside(pc):
        return DISP <= pc < DISP_END or CAVE <= pc < CAVE_END or SWITCH8 <= pc < SWITCH8_END
    def on_block(uc, addr, size, ud):
        if addr == SENTINEL:
            uc.emu_stop(); return
        if not inside(addr):
            # a call out of the dispatcher: log (callee, r0, payload) and stub it
            r0, r1, r2 = (uc.reg_read(x) for x in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2))
            payload = bytes(uc.mem_read(r1, r2)).hex() if addr == SEND_REPLY and r2 <= 64 else ''
            log.append((NAMES.get(addr, f'fn_{addr:x}'), r0, payload))
            trash_caller_saved(uc)
            uc.reg_write(UC_ARM_REG_PC, uc.reg_read(UC_ARM_REG_LR))
    uc.hook_add(UC_HOOK_BLOCK, on_block)
    err = None
    try:
        uc.emu_start(DISP | 1, 0, count=5000)
    except UcError as e:
        err = str(e)
    return log, err, regs(uc)

def test_trace(patched, clean):
    print('== 4. trace: clean vs patched call sequence for all 256 command bytes ==')
    diff = {}
    for cmd in range(256):
        lc, ec, rc = trace(clean, cmd)
        lp, ep, rp = trace(patched, cmd)
        assert ec is None and ep is None, (hex(cmd), ec, ep, lc, lp)
        assert rc['pc'] == SENTINEL and rp['pc'] == SENTINEL, (hex(cmd), rc, rp)
        assert rc['sp'] == STACK_TOP and rp['sp'] == STACK_TOP and rp['r4'] == R4_IN, (hex(cmd), rc, rp)
        if lc != lp: diff[cmd] = (lc, lp)
    assert list(diff) == [CMD], f'behaviour changed for commands: {[hex(c) for c in diff]}'
    lc, lp = diff[CMD]
    print('  255 commands: identical callee+argument traces; both images return to caller with sp balanced.')
    print(f'  0x5A clean  : {lc}')
    print(f'  0x5A patched: {lp}')
    assert lc == [('ble_rx_mark_activity', CMD, ''), ('reply_unsupported', CMD, '')]
    assert lp[0][0] == 'send_reply_payload' and lp[0][1] == CMD and len(lp) == 1
    print('  clean firmware treated 0x5A as unsupported (so the id was free); patched answers it.  OK')

if __name__ == '__main__':
    clean = open(CLEAN, 'rb').read(); patched = open(PATCHED, 'rb').read()
    assert len(clean) == len(patched)
    test_decode(patched, clean)
    test_passthru(patched, clean)
    test_accel(patched)
    test_trace(patched, clean)
    print('\nALL CHECKS PASSED on', os.path.basename(PATCHED))

# ---------------------------------------------------------------- 5. wire frame (real send_reply_payload -> checksum_u8 -> tx_enqueue_packet)
TX_ENQUEUE = 0x82dbc0; ROM_MEMCPY = 0x3f848
def test_wire(patched):
    print('== 5. wire: run the REAL reply path; capture the 16-byte frame at tx_enqueue_packet; parse with the host client ==')
    import importlib.util
    spec = importlib.util.spec_from_file_location('client', os.path.join(HERE, 'tap_and_accel_client.py'))
    client = importlib.util.module_from_spec(spec); spec.loader.exec_module(client)
    for head in (0, 6, 0x30, 0x1e6):
        uc = make_uc(patched); ring = seed_fifo(uc, head); setup_call(uc, CMD)
        uc.mem_map(0x30000, 0x10000)                     # ROM page holding memcpy (stubbed below)
        frames = []
        def hook(uc, addr, size, ud):
            if addr == ROM_MEMCPY:                       # ROM memcpy(dst, src, n) -> do it in Python, return
                d, s, n = (uc.reg_read(x) for x in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2))
                uc.mem_write(d, bytes(uc.mem_read(s, n)))
                uc.reg_write(UC_ARM_REG_PC, uc.reg_read(UC_ARM_REG_LR))
            elif addr == TX_ENQUEUE:                     # capture the frame the BLE layer would notify
                frames.append(bytes(uc.mem_read(uc.reg_read(UC_ARM_REG_R0), 16)))
                trash_caller_saved(uc)
                uc.reg_write(UC_ARM_REG_PC, uc.reg_read(UC_ARM_REG_LR))
            elif addr == SENTINEL:
                uc.emu_stop()
        uc.hook_add(UC_HOOK_CODE, hook)
        uc.emu_start(DISP | 1, 0, count=2000)
        r = regs(uc)
        assert len(frames) == 1 and r['pc'] == SENTINEL and r['sp'] == STACK_TOP and r['r4'] == R4_IN, (head, frames, r)
        f = frames[0]
        exp = newest_sample(ring, head)
        assert f[0] == CMD and f[1:7] == exp and f[7:15] == bytes(8) and f[15] == sum(f[:15]) & 0xff, (head, f.hex())
        got = []
        ring_obj = client.Ring(write_cmd=lambda b: None, on_accel=lambda x, y, z: got.append((x, y, z)))
        ring_obj.on_notify(f)
        assert got == [struct.unpack('<hhh', exp)], (head, got, exp)
        print(f'  head={head:#5x}: frame {f.hex()}  -> client parsed {got[0]}  OK')

# ---------------------------------------------------------------- 6. free command ids in the clean firmware
def test_free_ids(clean):
    print('== 6. free ids: which command bytes does the clean firmware answer with reply_unsupported? ==')
    free, handled = [], {}
    for cmd in range(256):
        lc, ec, rc = trace(clean, cmd)
        names = [n for n, _, _ in lc if n != 'ble_rx_mark_activity']
        if names == ['reply_unsupported']: free.append(cmd)
        else: handled[cmd] = names
    lo = [c for c in free if c < 0x80]
    print(f'  {len(free)} free ids; {len(lo)} below 0x80: {" ".join(f"{c:02x}" for c in lo)}')
    print(f'  0x32 handled as: {handled.get(0x32)}   (the old id 0xB2 == 0x32|0x80 was the error-reply form of 0x32; 0x5A has no such alias)')
    return free, handled

if __name__ == '__main__' and '--deep' in os.sys.argv:
    clean = open(CLEAN, 'rb').read(); patched = open(PATCHED, 'rb').read()
    test_wire(patched)
    test_free_ids(clean)
