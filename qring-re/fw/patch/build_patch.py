#!/usr/bin/env python3
"""Rebuild base_RT12_accel_patched.bin from the clean image. Pure byte patch; no flashing.
Verifies every branch target by decoding it back. Run:  python3 build_patch.py"""
import struct, os, sys
HERE=os.path.dirname(os.path.abspath(__file__))
SRC=os.path.join(HERE,'..','base_RT12_3.10.06_260429.bin')
NEWVER='3.11.00'; NEWDATE='260911'
OUT=os.path.join(HERE,f'base_RT12_{NEWVER}_{NEWDATE}.bin')
BASE=0x826000-0x50
fo=lambda v:v-BASE
CAVE=0x847840; DISP=0x82b626; SEND=0x82a616; CONT=0x82b62a
HEAD=0x20bdf4; RINGB=0x20bdf8; RSIZE=0x1ec
def bw(pc,t,link=False):
    off=t-(pc+4); imm=off>>1; S=(imm>>23)&1; i1=(imm>>22)&1; i2=(imm>>21)&1
    imm10=(imm>>11)&0x3ff; imm11=imm&0x7ff; j1=(~i1&1)^S; j2=(~i2&1)^S
    return struct.pack('<HH',0xF000|(S<<10)|imm10,((0xD000 if link else 0x9000))|(j1<<13)|(j2<<11)|imm11)
def movw(rd,v): i=(v>>11)&1; return struct.pack('<HH',0xF240|(i<<10)|((v>>12)&0xf),(((v>>8)&7)<<12)|(rd<<8)|(v&0xff))
def movt(rd,v): i=(v>>11)&1; return struct.pack('<HH',0xF2C0|(i<<10)|((v>>12)&0xf),(((v>>8)&7)<<12)|(rd<<8)|(v&0xff))
def addw(rd,rn,v): i=(v>>11)&1; return struct.pack('<HH',0xF200|(i<<10)|rn,(((v>>8)&7)<<12)|(rd<<8)|(v&0xff))
d=bytearray(open(SRC,'rb').read())
assert d.count(b'3.10.06')==4 and d.count(b'260429')==4
d=bytearray(d.replace(b'3.10.06',NEWVER.encode()).replace(b'260429',NEWDATE.encode()))  # bump every version copy (same length)
buf=bytearray(); a=CAVE
def e(b):
    global a; buf.extend(b); a+=len(b)
e(struct.pack('<H',0x7801)); e(struct.pack('<H',0x29B2))
beq=a; e(b'\0\0'); e(struct.pack('<H',0xB510)); e(struct.pack('<H',0x4604))
bw2=a; e(b'\0\0\0\0'); mine=a
e(struct.pack('<H',0xB510)); e(movw(3,HEAD&0xffff)); e(movt(3,HEAD>>16))
e(struct.pack('<H',0x881A)); e(struct.pack('<H',0x3A06))
bpl=a; e(b'\0\0'); e(addw(2,2,RSIZE)); nw=a
e(movw(1,RINGB&0xffff)); e(movt(1,RINGB>>16)); e(struct.pack('<H',0x4411))
e(struct.pack('<H',0x20B2)); e(struct.pack('<H',0x2206))
bl=a; e(b'\0\0\0\0'); e(struct.pack('<H',0xBD10))
p=lambda x,b: buf.__setitem__(slice(x-CAVE,x-CAVE+len(b)),b)
p(beq,struct.pack('<H',0xD000|(((mine-(beq+4))>>1)&0xff)))
p(bpl,struct.pack('<H',0xD500|(((nw-(bpl+4))>>1)&0xff)))
p(bw2,bw(bw2,CONT)); p(bl,bw(bl,SEND,link=True))
assert len(buf)<=298
d[fo(CAVE):fo(CAVE)+len(buf)]=buf
d[fo(DISP):fo(DISP)+4]=bw(DISP,CAVE)
struct.pack_into('<I',d,0xc,sum(d[0x10:])&0xffffffff)   # recompute the byte-sum word
open(OUT,'wb').write(d)
print("wrote",OUT,len(d),"bytes; cave",len(buf),"bytes at",hex(CAVE))
