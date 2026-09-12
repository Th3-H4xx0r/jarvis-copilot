// Pre-analysis: memory map + Thumb mode + entry points for the RT12 (RTL8762) app image.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.symbol.SourceType;
import java.math.BigInteger;

public class SetupRT12 extends GhidraScript {
    private Address a(long v) { return currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(v); }
    private void blk(String name, long start, long len, boolean x) throws Exception {
        Memory m = currentProgram.getMemory();
        if (m.getBlock(a(start)) != null) return;
        MemoryBlock b = m.createUninitializedBlock(name, a(start), len, false);
        b.setRead(true); b.setWrite(true); b.setExecute(x);
    }
    @Override
    public void run() throws Exception {
        Memory mem = currentProgram.getMemory();
        MemoryBlock app = mem.getBlock(a(0x00826400L));
        app.setName("APP_FLASH"); app.setExecute(true); app.setWrite(false);
        blk("ROM_LOW",   0x00000000L, 0x00100000L, true);   // mask ROM (memcpy/memset etc.)
        blk("ROM_HIGH",  0x00400000L, 0x00100000L, true);   // more ROM/patch (0x0047xxxx refs)
        blk("FLASH_LOW", 0x00800000L, 0x00026400L, true);   // OTA header / patch / config below app
        blk("SRAM",      0x00200000L, 0x00040000L, true);   // data RAM 0x0020xxxx
        blk("PERIPH",    0x40000000L, 0x00100000L, false);
        blk("SCS",       0xE000E000L, 0x00001000L, false);
        // Whole app is Thumb
        Register tmode = currentProgram.getRegister("TMode");
        currentProgram.getProgramContext().setValue(tmode, app.getStart(), app.getEnd(), BigInteger.ONE);
        // Entry points
        long[] entries = {0x00826400L, 0x00826664L};
        for (long e : entries) {
            Address ad = a(e);
            disassemble(ad);
            createFunction(ad, e == 0x00826400L ? "entry_trampoline" : "reset_handler");
            currentProgram.getSymbolTable().addExternalEntryPoint(ad);
        }
        println("SetupRT12 done");
    }
}
