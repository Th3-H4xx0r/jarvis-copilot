@ RT12_3.10.06 patch: expose accelerometer samples over BLE (new command 0x5A).
@ Placed in the tail code-cave at 0x847840 (298 zero bytes inside the mapped image).
@ Hook: the first 4 bytes of ble_cmd_dispatch (0x82b626: "push {r4,lr}; mov r4,r0")
@ are replaced with "b.w cave". The cave intercepts cmd 0x5A and otherwise replays
@ the two displaced instructions and returns into the dispatcher at 0x82b62a.
@
@ Protocol added:  phone -> ring   16-byte frame, byte[0]=0x5A  (poll)
@                  ring  -> phone   16-byte frame, byte[0]=0x5A, [1..6]=x,y,z int16 LE
@ The phone polls 0x5A as fast as it likes; each reply is the most recent FIFO sample.
@
@ Registers at cave entry (branched from dispatch's 1st instruction): r0=packet ptr, lr=caller.
        .syntax unified
        .thumb
        .equ ACCEL_FIFO_HEAD, 0x20bdf4      @ u16 byte-offset head into the sample ring
        .equ ACCEL_FIFO_BASE, 0x20bdf8      @ ring of interleaved x,y,z int16 (stride 6, size 0x1ec)
        .equ RING_SIZE,       0x1ec
        .equ SEND_REPLY,      0x82a616      @ send_reply_payload(r0=cmd, r1=buf, r2=len)
        .equ DISPATCH_CONT,   0x82b62a      @ ble_cmd_dispatch + 4  (the displaced "ldrb r0,[r0]")
cave:
        ldrb    r1, [r0]                    @ cmd = packet[0]
        cmp     r1, #0x5A
        beq     .Lmine
        push    {r4, lr}                    @ --- not ours: replay displaced instrs ...
        mov     r4, r0
        b.w     DISPATCH_CONT               @     ... and fall back into the dispatcher
.Lmine:
        push    {r4, lr}
        movw    r3, #(ACCEL_FIFO_HEAD & 0xffff)
        movt    r3, #(ACCEL_FIFO_HEAD >> 16)
        ldrh    r2, [r3]                    @ r2 = head (byte offset of next write)
        subs    r2, r2, #6                  @ step back to the most recent sample
        bpl     .Lnowrap
        addw    r2, r2, #RING_SIZE          @ wrap
.Lnowrap:
        movw    r1, #(ACCEL_FIFO_BASE & 0xffff)
        movt    r1, #(ACCEL_FIFO_BASE >> 16)
        add     r1, r1, r2                  @ r1 = &sample (6 contiguous bytes: x,y,z LE)
        movs    r0, #0x5A                   @ reply command id
        movs    r2, #6                      @ payload length
        bl      SEND_REPLY                  @ send_reply_payload(0x5A, &sample, 6)
        pop     {r4, pc}                    @ return to the dispatcher's caller
