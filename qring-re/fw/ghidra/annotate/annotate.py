#!/usr/bin/env python3
"""Turn Ghidra's raw export (RT12_3.10.06.raw.c) into the readable RT12_3.10.06.c.

Steps: rename functions/globals from names.py, rewrite ARM switch8 case labels to the
real case values (tables parsed from the firmware binary), add a description block to
every function (hand-written or generated), and prepend a subsystem index.
"""
import re, sys, csv, struct, os, collections
sys.path.insert(0, os.path.dirname(__file__))
import names as N

HERE = os.path.dirname(os.path.abspath(__file__))
FW   = os.path.abspath(os.path.join(HERE, '..', '..'))
RAW  = os.path.join(FW, 'decompiled', 'RT12_3.10.06.raw.c')
OUT  = os.path.join(FW, 'decompiled', 'RT12_3.10.06.c')
CSV  = os.path.join(FW, 'decompiled', 'functions.csv')
BIN  = os.path.join(FW, 'base_RT12_3.10.06_260429.bin')
BASE = 0x826000 - 0x50           # vaddr = file_offset + BASE

# switch8 sites whose index is (value - base): value = base + index
SWITCH_BASES = {0x82b6e0: 0x7a, 0x82eeba: 0x22, 0x83afe6: 4}
SWITCH_INDEX_ONLY = {0x82de2a, 0x82f3c2, 0x834efa, 0x8350ea}   # base not proven: labels are the raw index

src = open(RAW).read()
fw  = open(BIN, 'rb').read()
def fwb(vaddr): return fw[vaddr - BASE]

# ---------------------------------------------------------------- names
rename = {}
for addr, (nm, _) in N.FUNCS.items(): rename[f"FUN_{addr:08x}"] = nm
for addr, (nm, _) in N.ROM.items():   rename[f"FUN_{addr:08x}"] = nm
rename.update(N.GLOBALS)
# Ghidra already applied a few names in the export; make sure our spelling wins
already = {"rx_prefilter": "ble_rx_mark_activity", "switch_table_helper": "switch_table_helper"}
rename.update(already)
pat = re.compile(r'\b(' + '|'.join(map(re.escape, sorted(rename, key=len, reverse=True))) + r')\b')
src = pat.sub(lambda m: rename[m.group(1)], src)
# thunks keep their target name
src = re.sub(r'\bthunk_(\w+)', lambda m: 'thunk_' + rename.get(m.group(1), m.group(1)), src)

# ---------------------------------------------------------------- switch labels
def switch_table(table):
    cnt = fwb(table)
    return [table + fwb(table + 1 + i) * 2 for i in range(cnt + 1)], cnt

def relabel_block(text, table):
    """Rewrite 'case <off>:' lines of one switch block for the given table address."""
    targets, cnt = switch_table(table)
    base = SWITCH_BASES.get(table, 0)
    idx_only = table in SWITCH_INDEX_ONLY
    by_target = collections.defaultdict(list)
    for i, t in enumerate(targets[:-1]): by_target[t].append(i)
    def fix(m):
        ind, lab = m.group(1), int(m.group(2), 0)
        t = table + lab
        if t not in by_target: return m.group(0)
        vals = by_target[t]
        lines = [f"{ind}case {base + v:#x}:" for v in vals]
        if idx_only: lines[0] += "   // (index into the switch8 table; base not verified)"
        return "\n".join(lines)
    return re.sub(r'^(\s*)case (0x[0-9a-f]+|\d+):$', fix, text, flags=re.M)

# generic form:  switch((uint)(&BYTE_0082b3df)[uVar2] * 2) {  or (byte)(&UNK_..)[..]
def relabel_generic(fn_text):
    m = re.search(r'switch\((\(uint\)(?:\(byte\))?\(&(?:BYTE|UNK)_([0-9a-f]{8})\)\[(\w+)\] \* 2)\)', fn_text)
    if not m:
        # non-standard forms: the table pointer is computed on a separate line
        if 'Switch is manually overridden' not in fn_text: return fn_text
        m2 = re.search(r'(?:BYTE|UNK)_([0-9a-f]{8})\)\[', fn_text) or re.search(r'\+ 0x(8[0-9a-f]{5})\)', fn_text)
        if not m2: return fn_text
        x = int(m2.group(1), 16)
        table = x - 1
        for t, b in SWITCH_BASES.items():          # pointer may already have the base folded in
            if t + 1 - b == x: table = t
        base = SWITCH_BASES.get(table, 0)
        fn_text = re.sub(r'^(\s*)switch\((.*)\) \{$', lambda mm: f"{mm.group(1)}switch({mm.group(2)})   /* switch8 jump table at {table:#x}; case values below are the real input values{' (+' + hex(base) + ')' if base else ''} */ {{", fn_text, count=1, flags=re.M)
        return relabel_block(fn_text, table)
    table = int(m.group(2), 16) - 1
    base = SWITCH_BASES.get(table, 0)
    var = m.group(3)
    head = f"switch({var}{' + ' + hex(base) if base else ''})   /* switch8 jump table at {table:#x}; case values are the real {'index' if table in SWITCH_INDEX_ONLY else 'input'} values */"
    fn_text = fn_text[:m.start()] + head + fn_text[m.end():]
    return relabel_block(fn_text, table)

funcs = re.split(r'\n(?=// =+\n// )', src)
head, funcs = funcs[0], funcs[1:]

def fn_meta(f):
    m = re.match(r'// =+\n// (\S+) @ (0x[0-9a-f]+)\s+size=(\d+)\s+callers=(\d+)\s+callees=(\d+)', f)
    return (m.group(1), int(m.group(2), 16), int(m.group(3)), int(m.group(4)), int(m.group(5))) if m else None

out_funcs = []
for f in funcs:
    meta = fn_meta(f)
    if not meta: out_funcs.append(f); continue
    name, addr, *_ = meta
    if addr == 0x82b626:
        # the dispatcher has two switch8 blocks; decompiler order is [table 0x82b6e0, table 0x82b64c]
        parts = re.split(r'(?=\n\s*switch\()', f)
        assert len(parts) == 3, len(parts)
        parts[1] = relabel_block(parts[1], 0x82b6e0)
        parts[2] = relabel_block(parts[2], 0x82b64c)
        f = "".join(parts)
        f = f.replace("switch((uint)*pbVar1 * 2) {", "switch(uVar2)   /* switch8 table at 0x82b6e0: commands 0x7a..0xa1 (index clamps into the table) */ {", 1)
        f = f.replace("switch((uint)(&BYTE_0082b64d)[uVar2] * 2) {", "switch(uVar2)   /* switch8 table at 0x82b64c: commands 0x00..0x28 */ {", 1)
    else:
        f = relabel_generic(f)
    out_funcs.append(f)
funcs = out_funcs

# ---------------------------------------------------------------- descriptions
def region_of(addr):
    for lo, hi, lab in N.REGIONS:
        if lo <= addr <= hi: return lab
    return "ROM (mask ROM, not in image)" if addr < 0x800000 else "unclassified"

descs = {a: d for a, (_, d) in N.FUNCS.items()}
descs.update({a: d for a, (_, d) in N.ROM.items()})

def gen_desc(f, meta):
    name, addr, size, callers, callees = meta
    body = f.split('\n{', 1)[1] if '\n{' in f else f
    strs = re.findall(r'"((?:[^"\\]|\\.){3,})"', body)
    calls = collections.Counter(re.findall(r'\b([A-Za-z_]\w*)\(', body))
    for k in ('if', 'while', 'for', 'switch', 'return', 'sizeof', 'CONCAT11', 'CONCAT12', 'CONCAT13', 'CONCAT22', 'CONCAT31', 'CONCAT44', 'SUB41', 'SBORROW4', name):
        calls.pop(k, None)
    named = [c for c in calls if not c.startswith(('FUN_', 'thunk_FUN_', 'switchD', 'LAB_'))]
    unnamed = [c for c in calls if c.startswith(('FUN_', 'thunk_FUN_'))]
    glob = re.findall(r'\b([a-z][a-z0-9_]+|DAT_0020[0-9a-f]{4})\b', body)
    glob = [g for g in dict.fromkeys(glob) if g in N.GLOBALS.values() or g.startswith('DAT_0020')]
    parts = []
    if 'tx_enqueue_packet' in calls:
        m = re.search(r'local_\w+ = (0x[0-9a-f]{1,2}|\d{1,3});', body)
        cmd = f" (first byte looks like cmd {int(m.group(1),0):#04x})" if m and 0 < int(m.group(1), 0) < 0x100 else ""
        parts.append(f"Builds and queues one or more 16-byte BLE packets{cmd}.")
    if any(c.startswith('accel_i2c') for c in named): parts.append("Accelerometer register access.")
    if 'os_timer_create' in calls:
        tm = [s for s in strs if 'timer' in s.lower() or '_id' in s]
        parts.append("Creates timer(s) " + ", ".join(f"'{t}'" for t in tm) + "." if tm else "Creates an OS timer.")
    if 'send_msg_to_hub_task' in calls: parts.append("Posts work to the hub task.")
    if 'app_send_msg_to_apptask' in calls or 'app_post_msg' in calls: parts.append("Posts a message to the app task.")
    if 'log_direct' in calls and strs: parts.append("Logs: " + "; ".join(f"'{s}'" for s in strs[:3]) + ".")
    elif strs: parts.append("Strings: " + ", ".join(f"'{s}'" for s in strs[:3]) + ".")
    if named: parts.append("Calls " + ", ".join(named[:8]) + (f" and {len(named)-8} more" if len(named) > 8 else "") + ".")
    if unnamed: parts.append(f"Also calls {len(unnamed)} unnamed function(s).")
    if not named and not unnamed and size <= 16: parts.append("Tiny leaf helper (accessor / stub).")
    if glob: parts.append("Globals: " + ", ".join(glob[:5]) + (", ..." if len(glob) > 5 else "") + ".")
    if callers == 0: parts.append("No direct callers: reached via a function pointer, table, or ISR.")
    return " ".join(parts) if parts else "No distinguishing features; see body."

annotated = []
index = collections.defaultdict(list)
rows = []
for f in funcs:
    meta = fn_meta(f)
    if not meta: annotated.append(f); continue
    name, addr, size, callers, callees = meta
    region = region_of(addr)
    hand = descs.get(addr)
    d = hand if hand else gen_desc(f, meta)
    tag = "" if hand else " [auto]"
    # wrap the description at ~100 cols
    words, lines, cur = d.split(), [], ""
    for w in words:
        if len(cur) + len(w) + 1 > 100: lines.append(cur); cur = w
        else: cur = (cur + " " + w).strip()
    lines.append(cur)
    block = f"// Module: {region}\n" + "\n".join(f"// {'What: ' if i == 0 else '      '}{l}{tag if i == len(lines)-1 else ''}" for i, l in enumerate(lines))
    f = re.sub(r'^(// \S+ @ 0x[0-9a-f]+.*\n(?:// called from:.*\n)?)', lambda m: m.group(1) + block + "\n", f, count=1, flags=re.M)
    annotated.append(f)
    rows.append((addr, name, size, callers, callees, d))
    if hand: index[region].append((addr, name, d.split('. ')[0].rstrip('.')))

toc = ["// ============================================================================",
       "// INDEX OF NAMED FUNCTIONS (by subsystem).  Every function below also carries a",
       "// '// Module:' line and a '// What:' description; '[auto]' marks generated ones.",
       "// ============================================================================"]
for lo, hi, lab in N.REGIONS:
    if lab not in index: continue
    toc.append(f"//\n// --- {lab}  ({lo:#x}..{hi:#x})")
    for addr, nm, short in sorted(index[lab]):
        toc.append(f"//   {nm:34s} @ {addr:#010x}  {short[:80]}")
toc.append("//\n// --- ROM routines referenced (mask ROM, bodies not in this image)")
for addr, (nm, d) in sorted(N.ROM.items()):
    toc.append(f"//   {nm:34s} @ {addr:#010x}  {d.split('. ')[0][:80]}")
toc.append("//\n// --- Named globals (SRAM unless noted) are listed in names.py (GLOBALS).\n")

head = head.rstrip() + "\n\n" + "\n".join(toc) + "\n"
open(OUT, 'w').write(head + "\n".join(annotated))
with open(CSV, 'w', newline='') as fh:
    w = csv.writer(fh); w.writerow(["address", "name", "size_bytes", "callers", "callees", "description"])
    for r in sorted(rows): w.writerow([f"0x{r[0]:08x}", *r[1:]])
print(f"wrote {OUT}: {len(rows)} functions, {sum(len(v) for v in index.values())} hand-named")
