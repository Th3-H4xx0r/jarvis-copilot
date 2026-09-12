# RT12_3.10.06 — decompiled C (Ghidra 12.1.3)

Human-readable output of the ring's running firmware `base_RT12_3.10.06_260429.bin`
(Colmi/YaWell R12, Realtek RTL8762, Cortex-M Thumb-2). Generated headlessly by
`../ghidra/scripts/{SetupRT12,ExportRT12}.java`; the Ghidra project itself is in
`../ghidra/proj/RT12.gpr` (open with `~/tools/ghidra_12.1.3_PUBLIC/ghidraRun` to browse,
rename, and re-decompile interactively).

| File | What |
|---|---|
| `RT12_3.10.06.c` | all 1,499 functions, decompiled, in address order (~46k lines) |
| `functions.csv` | address, name, size, caller/callee counts — use it as the index |
| `strings.csv` | string literals Ghidra recognised, with addresses |

## How to read it

- Each function starts with `// name @ 0xADDR size=… callers=… callees=…` and a
  `// called from:` line, so you can walk the call graph with plain grep.
- `FUN_xxxxxxxx` = auto-named. `DAT_0020xxxx` = a global in SRAM. `DAT_0084xxxx` = a
  constant in flash. String literals are inlined where they are used.
- Names that are NOT auto-generated came from three sources:
  1. Hand-verified in `../README.md`: `checksum_u8`, `reply_unsupported`,
     `tx_enqueue_packet`, `send_chunked`, `ble_cmd_dispatch`, `queue_cmd_for_task`,
     `rom_memcpy`, `rom_memset`.
  2. Exact signature match with the Realtek SDK: `rom_os_timer_create(&handle, "name", id,
     interval_ms, reload, callback)`, `rom_os_mem_alloc_intern(0, size, "malloc", line)`.
  3. The function's own log/tag string (`cfg_add_item`, `gsensor_timers_init`,
     `lis3dh_spi_read_task`, `gsensor_*_timer_cb` (from the timer-create callback args), `hr_module_fn_*`, `print_sdk_version`, …). Treat these as
     labels for where a string lives, not proof of what the whole function does.
- `rom_*` functions live in the mask ROM (addresses `0x000xxxxx`/`0x004xxxxx`) which is
  NOT in this image: you see the calls but never the bodies. `rom_log_trace` /
  `rom_log_print` are the Realtek DBG_BUFFER back-ends (first arg is a module/level word).

## Where to start

| Want | Look at |
|---|---|
| boot | `entry_trampoline` (0x826400) → `reset_handler` (0x826664) |
| BLE command handling | `ble_cmd_dispatch` (0x82b626) → per-command builders (the 50 callers of `checksum_u8`) |
| packet TX | `tx_enqueue_packet` (0x82dbc0), `send_chunked` (0x82b9de) |
| gesture / accelerometer | `gsensor_timers_init` (0x832f3a), `lis3dh_spi_read_task` (0x832f92) and the 2000 ms timers they create |
| heart rate / SpO2 | `hr_module_fn_a/b` (0x833aee/0x833bac), `hr_algo_core30fx_init` (0x8373c8) |
| settings storage | `cfg_add_item` (0x840674), `cfg_write_to_flash` (0x8403f4) |
| OTA | `ota_header_check` (0x84085c, "Header is invalid") |
| the three biggest state machines | `FUN_00841d94` (2.8 KB), `FUN_0083f278` (2.5 KB), `FUN_008428bc` (2.1 KB) |

## Caveats

- Coverage: 117,016 of 136,852 payload bytes are inside functions; the rest is data
  (tables, strings, the IRQ-name table) plus a little code Ghidra could not reach.
- Decompiler output is a reconstruction. Odd-looking returns (e.g. `CONCAT44(...)` in
  `reply_unsupported`) are artefacts of unknown calling conventions, not real behaviour.
- Peripheral registers appear as raw `0x4000xxxx` addresses; map them with the RTL8762C
  datasheet when needed.
