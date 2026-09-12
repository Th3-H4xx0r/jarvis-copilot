# RT12 firmware — static analysis of `RT12_3.10.06_260429`

What was recovered from `base_RT12_3.10.06_260429.bin` (the image the ring is running).

## Container layout

| Range | Size | Contents |
|---|---|---|
| `0x000`–`0x04F` | 80 B | vendor wrapper: `checksum(4) \| len(4) \| len(4) \| checksum(4) \| "RT12_3.10.06_260429"\0 \| "RT12_V3.1"\0` |
| `0x050`–`0x44F` | 1 KiB | Realtek image header (UUID, load/entry addresses, `sdk#####` tag) |
| `0x450`–EOF | 134 KiB | Realtek app image — **Thumb-2 code + rodata** |

**Load address: `0x0082_6400`.  `vaddr = file_offset + 0x825FB0`.**

Confirmed two ways: the entry trampoline at `0x450` is `ldr r0,[pc]; bx r0` → `0x00826665`,
and literal-pool pointers resolve exactly onto known strings (`hr_module.c` at `0x00833B74`,
the IRQ-name table at `0x008467B0`).

Memory map implied by literal pools (consistent with RTL8762):
`0x0020_xxxx` SRAM (272 ptrs) · `0x008x_xxxx` mapped flash · `0x4000/0x4001_xxxx` peripherals ·
`0xE000_xxxx` Cortex-M SCB/NVIC · low addresses (`0x0003_xxxx`, `0x0047_xxxx`) = **ROM**
(`memcpy` at `0x3F848`, `memset` at `0x3F8CA` live there — patching them is not possible).

Disassembly: **54,871 instructions = 86.3% of the payload**, 1,581 function candidates,
1,043 of them call targets. Full listing in `RT12_3.10.06_disassembly.asm` (73k lines).

## BLE packet format (recovered, not guessed)

Every packet is **exactly 16 bytes**:

```
[0]      command id
[1..14]  payload
[15]     checksum = sum(bytes[0..14]) & 0xFF
```

From `checksum_u8` @ `0x00829E98` — a 16-bit accumulate truncated to 8 bits — and its use at
`0x0082BA14` (`len = 0x0F`, result stored at `[15]`).

The RX path validates `length == 0x10` before dispatching (`0x0082B9BE`).

Chunked/multi-packet sends (`send_chunked` @ `0x0082B9DE`) use `[1] = sequence`, starting at 1
and incrementing, with **13 payload bytes per packet** at offset `+2`.

TX is queued: `tx_enqueue_packet` @ `0x0082DBC0` copies into a 128-slot × 16-byte ring at
SRAM `0x00209E74+2`, wraps at `0x7F`, then kicks the sender.

## Unsupported-command reply — a free capability probe

`reply_unsupported` @ `0x0082A98E` decompiles exactly to:

```c
void reply_unsupported(uint8_t cmd) {
    uint8_t pkt[16] = {0};
    pkt[0]  = cmd | 0x80;
    pkt[1]  = 0xEE;
    pkt[15] = (uint8_t)((cmd | 0x80) + 0xEE);
    tx_enqueue_packet(pkt);
}
```

**So the ring tells you what it supports.** Send any opcode; if the reply is
`[cmd|0x80, 0xEE, 0…]` the firmware has no handler for it. Anything else means it is handled.
This makes opcode discovery safe and exhaustive at runtime — no firmware flashing needed.

154 of 256 opcodes land here. The other 102 are handled; see `opcode_map.txt`.

## Dispatcher structure

Entry `ble_cmd_dispatch` @ `0x0082B626`:

1. For every command **except `0x43` and `0x48`**, a pre-hook at `0x0082DEA2` runs first.
2. Dispatch is a binary compare-tree plus two `__ARM_common_switch8` jump tables
   (helper @ `0x0084027C`, inline `[count][offset…]` table, target = `table_base + 2*offset`):
   - table 1 covers `0x00`–`0x27`
   - table 2 covers `0x7A`–`0xA0` (indexed by `cmd - 0x7A`)
3. Each case is a thunk `mov r0, r4; bl <handler>; b epilogue`.

Handlers split into two classes:

- **Inline** — handled synchronously, reply built and queued immediately.
- **Deferred** — `queue_cmd_for_task` @ `0x0082AB6C` copies the packet into a 10-slot ring at
  SRAM `0x00209D70+4` and posts event `0x33C` to a task. Commands `0x01 05 08 0E 15 18 37 39
  3A 3B 72 77 A1 C6 C7 FF` take this path — i.e. the slow ones (time set, history reads, and
  **`0x3B` gesture config**).

## Notable handlers

| Cmd | Handler | Note |
|---|---|---|
| `0x03` | `0x0082A950` | |
| `0x0D` | `0x00834536` | separate subsystem (called direct, not via thunk) |
| `0x50` | `0x00829B38` | calls `0x0083A58A(1, 1, 10)` after |
| `0x69` | `0x0082B0A8` | realtime reading **start** |
| `0x6A` | `0x0082AF5A` | realtime reading **stop** |
| `0x3B` | deferred | gesture/sensitivity — the tap-threshold knob |
| `0xBF` `0xC0` `0xC4` `0xCD` `0xCE` | various | **high opcodes absent from the app** — undocumented |

The `0xBF`–`0xFF` range is worth probing: those handlers exist in firmware but the phone app
never sends them.

## What this does NOT give you

The original C source is **not** recoverable — this is stripped, optimized Thumb with no
symbol table and no debug info. What exists is the disassembly plus per-function decompilation
by hand. Only two source paths survived as strings:
`qc_code\app_module\gsensor\lis3dh_spi.c` and `qc_code\app_module\hr\hr_module.c`.

## Tools

`tools/analyze.py` (recursive-descent + xrefs) · `tools/dumpfn.py <addr> [n]` (annotated
single-function dump) · `tools/opcodes2.py` (symbolic dispatcher walk → opcode map) ·
`tools/switches.py` (jump-table / compare-chain finder) · `tools/listing.py` (full listing).

Needs `capstone`: `python3 -m venv venv && venv/bin/pip install capstone`.

## Decompiled C (added 2026-09-11)

`decompiled/RT12_3.10.06.c` — all 1,499 functions as C via Ghidra 12.1.3 (headless scripts in
`ghidra/scripts/`, project in `ghidra/proj/`). See `decompiled/README.md` for the reading guide.
Ghidra's macOS native decompiler is not shipped in 12.x; it was built from the bundled sources
into `~/tools/ghidra_12.1.3_PUBLIC/Ghidra/Features/Decompiler/os/mac_arm_64/`.
