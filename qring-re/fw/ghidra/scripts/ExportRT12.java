// Post-analysis: sweep for missed prologues, apply known names, export decompiled C.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.symbol.*;
import ghidra.program.model.data.*;
import ghidra.util.task.ConsoleTaskMonitor;
import ghidra.program.model.pcode.JumpTable;
import ghidra.app.cmd.function.CreateFunctionCmd;
import java.io.*;
import java.util.*;

public class ExportRT12 extends GhidraScript {
    private Address a(long v) { return currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(v); }

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        File outDir = new File(args.length > 0 ? args[0] : "decompiled");
        outDir.mkdirs();
        Listing listing = currentProgram.getListing();
        Memory mem = currentProgram.getMemory();
        MemoryBlock app = mem.getBlock(a(0x00826400L));

        // 1. Prologue sweep: push {.., lr} (b5xx) or push.w (e92d 4xxx) at an address with no code yet.
        int swept = 0;
        for (long p = app.getStart().getOffset(); p < app.getEnd().getOffset() - 4; p += 2) {
            Address ad = a(p);
            if (listing.getInstructionAt(ad) != null || listing.getDefinedDataAt(ad) != null) continue;
            if (listing.getInstructionContaining(ad) != null || listing.getDefinedDataContaining(ad) != null) continue;
            int lo = mem.getByte(ad) & 0xff, hi = mem.getByte(ad.add(1)) & 0xff;
            boolean push16 = (hi == 0xb5);
            boolean push32 = (lo == 0x2d && hi == 0xe9 && ((mem.getByte(ad.add(3)) & 0x40) != 0));
            if (!push16 && !push32) continue;
            if (disassemble(ad) && listing.getInstructionAt(ad) != null) {
                if (createFunction(ad, null) != null) swept++;
            }
        }
        println("prologue sweep created " + swept + " functions");
        analyzeChanges(currentProgram);

        // 1b. ARM "switch8" jump tables: the helper at 0x84027c is followed at the call return
        //     address by [count][count+1 byte offsets]; target = table + off*2 (index clamped to count).
        Address helper = a(0x0084027cL);
        ReferenceManager rm = currentProgram.getReferenceManager();
        int fixed = 0;
        for (Reference ref : rm.getReferencesTo(helper)) {
            if (!ref.getReferenceType().isCall()) continue;
            Address site = ref.getFromAddress();
            Instruction bl = listing.getInstructionAt(site);
            if (bl == null) continue;
            Address table = site.add(bl.getLength());
            int count = mem.getByte(table) & 0xff;
            List<Address> targets = new ArrayList<>();
            for (int i = 0; i <= count; i++) {
                int off = mem.getByte(table.add(1 + i)) & 0xff;
                targets.add(table.add(off * 2));
            }
            for (Address t : targets) {
                if (listing.getInstructionAt(t) == null) disassemble(t);
                rm.addMemoryReference(site, t, RefType.COMPUTED_JUMP, SourceType.USER_DEFINED, 0);
            }
            Function f = listing.getFunctionContaining(site);
            if (f != null) {
                new JumpTable(site, new ArrayList<>(targets), true, 0).writeOverride(f);
                CreateFunctionCmd.fixupFunctionBody(currentProgram, f, monitor);
                fixed++;
            }
            println(String.format("switch8 @%s: %d cases -> %s .. %s", site, count + 1, targets.get(0), targets.get(count)));
        }
        println("switch8 tables overridden: " + fixed);
        analyzeChanges(currentProgram);

        // 2. Known names from earlier manual analysis (qring-re/fw/README.md).
        Object[][] names = {
            {0x00829E98L, "checksum_u8"}, {0x0082A98EL, "reply_unsupported"}, {0x0082DBC0L, "tx_enqueue_packet"},
            {0x0082B9DEL, "send_chunked"}, {0x0082B626L, "ble_cmd_dispatch"}, {0x0082AB6CL, "queue_cmd_for_task"},
            {0x0084027CL, "switch_table_helper"}, {0x0082DEA2L, "rx_prefilter"},
        };
        for (Object[] n : names) {
            Address ad = a((Long) n[0]);
            Function f = listing.getFunctionAt(ad);
            if (f == null) { disassemble(ad); f = createFunction(ad, (String) n[1]); }
            if (f != null) f.setName((String) n[1], SourceType.USER_DEFINED);
        }

        // 3. Name the string literals so the C shows them.
        // (Ghidra's analyzers already create s_ labels; nothing to do.)

        // 4. Decompile everything, ordered by address.
        DecompInterface dec = new DecompInterface();
        DecompileOptions opts = new DecompileOptions();
        dec.setOptions(opts);
        dec.toggleCCode(true);
        dec.toggleSyntaxTree(false);
        dec.setSimplificationStyle("decompile");
        dec.openProgram(currentProgram);

        List<Function> funcs = new ArrayList<>();
        for (Function f : listing.getFunctions(true)) if (app.contains(f.getEntryPoint())) funcs.add(f);
        funcs.sort(Comparator.comparing(Function::getEntryPoint));
        println("decompiling " + funcs.size() + " functions");

        try (PrintWriter c = new PrintWriter(new FileWriter(new File(outDir, "RT12_3.10.06.raw.c")));
             PrintWriter idx = new PrintWriter(new FileWriter(new File(outDir, "functions.csv")))) {
            c.println("// Ghidra decompilation of RT12_3.10.06_260429 (Colmi/YaWell R12 ring, Realtek RTL8762, Cortex-M Thumb-2)");
            c.println("// App image loaded at 0x00826400. SRAM 0x0020xxxx, ROM 0x000xxxxx/0x004xxxxx (not in image), peripherals 0x400xxxxx.");
            c.println("// Functions are in address order. Names FUN_xxxxxxxx are auto-generated; DAT_/s_ are data/string labels.");
            c.println();
            idx.println("address,name,size_bytes,callers,callees");
            int i = 0, failed = 0;
            for (Function f : funcs) {
                if (monitor.isCancelled()) break;
                i++;
                if (i % 100 == 0) println("  " + i + "/" + funcs.size());
                int callers = f.getCallingFunctions(monitor).size();
                int callees = f.getCalledFunctions(monitor).size();
                idx.println(String.format("0x%08x,%s,%d,%d,%d", f.getEntryPoint().getOffset(), f.getName(), f.getBody().getNumAddresses(), callers, callees));
                c.println("// ============================================================================");
                c.println(String.format("// %s @ 0x%08x  size=%d  callers=%d  callees=%d", f.getName(), f.getEntryPoint().getOffset(), f.getBody().getNumAddresses(), callers, callees));
                Set<String> callerNames = new TreeSet<>();
                for (Function cf : f.getCallingFunctions(monitor)) callerNames.add(cf.getName());
                if (!callerNames.isEmpty()) c.println("// called from: " + String.join(", ", callerNames));
                DecompileResults r = dec.decompileFunction(f, 60, monitor);
                if (r != null && r.decompileCompleted() && r.getDecompiledFunction() != null) {
                    c.println(r.getDecompiledFunction().getC());
                } else {
                    failed++;
                    c.println("// DECOMPILE FAILED: " + (r == null ? "null" : r.getErrorMessage()));
                    c.println();
                }
            }
            println("done: " + i + " functions, " + failed + " failed");
        }
        dec.dispose();

        // 5. Strings table for orientation.
        try (PrintWriter s = new PrintWriter(new FileWriter(new File(outDir, "strings.csv")))) {
            s.println("address,string");
            DataIterator it = listing.getDefinedData(true);
            while (it.hasNext()) {
                Data d = it.next();
                if (d.getDataType() instanceof StringDataType || d.getDataType() instanceof TerminatedStringDataType) {
                    Object v = d.getValue();
                    if (v != null) s.println(String.format("0x%08x,\"%s\"", d.getAddress().getOffset(), v.toString().replace("\"", "\"\"").replace("\n","\\n")));
                }
            }
        }
    }
}
