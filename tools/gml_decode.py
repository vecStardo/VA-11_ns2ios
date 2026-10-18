import struct,sys,os
GAME=os.environ.get('VA11_GAME_WIN', os.path.expanduser('~/va11-work/orig/game.win'))
d=open(GAME,'rb').read()
strg=0xb301c0
def s_by_idx(i):
    if i>200000: return '?'
    p=strg+8+4*i
    if p+4>len(d): return '?'
    o=struct.unpack_from('<I',d,p)[0]
    if o+4>len(d): return '?'
    ln=struct.unpack_from('<I',d,o)[0]
    if ln<=0 or ln>200: return '?'
    try: return d[o+4:o+4+ln].decode('utf-8','replace')
    except Exception: return '?'
def s_ptr(p):
    if p<=0 or p>=len(d): return '<bad>'
    out=bytearray()
    for i in range(120):
        if p+i>=len(d): break
        c=d[p+i]
        if c<0x20 or c>0x7e: break
        out.append(c)
    return out.decode('ascii','replace')
vari=0xafaba0
_vcnt=struct.unpack_from('<I',d,vari+8)[0]
names=[]
_pos=vari+20
for i in range(_vcnt):
    name,it,vid,occ,first=struct.unpack_from('<IIIII',d,_pos)
    names.append(s_ptr(name)); _pos+=20

def code_bytes(entry):
    name,ln,loc,arg,f1,_=struct.unpack_from('<IIHHII',d,entry)
    if f1>=0x80000000: f1-=0x100000000
    a=entry+f1
    return d[a:a+ln], loc, arg
def decode(buf):
    pos=0; out=[]
    while pos+4<=len(buf):
        word=struct.unpack_from('<I',buf,pos)[0]; op=word>>24
        b0=word&0xFF; b1=(word>>8)&0xFF; b2=(word>>16)&0xFF
        t1=b2&0xF; t2=b2>>4; p0=pos; pos+=4
        u16=lambda: b0|(b1<<8)
        if op==0x84: out.append((p0,'pushim',u16())); continue
        if op in (0xC1,0xC2,0xC3):
            raw=u16(); vid=struct.unpack_from('<I',buf,pos)[0]; pos+=4
            out.append((p0,{0xC1:'pushloc',0xC2:'pushglb',0xC3:'pushbltn'}[op],names[vid] if vid<len(names) else hex(vid))); continue
        if op==0xC0:
            if t1==15: out.append((p0,'push.i16',u16()))
            elif t1==2: v=struct.unpack_from('<i',buf,pos)[0]; pos+=4; out.append((p0,'push.i32',v))
            elif t1 in (3,0): q=struct.unpack_from('<Q',buf,pos)[0]; pos+=8; out.append((p0,'push.dbl',q))
            elif t1==6: sid=struct.unpack_from('<I',buf,pos)[0]; pos+=4; out.append((p0,'push.str',sid))
            elif t1==5:
                raw=u16(); vid=struct.unpack_from('<I',buf,pos)[0]; pos+=4
                out.append((p0,'push.var',names[vid] if vid<len(names) else hex(vid)))
            elif t1==4: v=struct.unpack_from('<I',buf,pos)[0]; pos+=4; out.append((p0,'push.bool',v))
            else: out.append((p0,'push?',t1))
            continue
        if op==0xD9:
            argc=u16(); fid=struct.unpack_from('<I',buf,pos)[0]; pos+=4
            out.append((p0,'call',fid,argc)); continue
        if op==0x99: out.append((p0,'callvar',u16())); continue
        if op in (0xB6,0xB7,0xB8,0xBA,0xBB):
            v=b0|(b1<<8)|(b2<<16)
            if v&0x800000: v-=0x1000000
            out.append((p0,{0xB6:'jmp',0xB7:'jt',0xB8:'jf',0xBA:'pushenv',0xBB:'popenv'}[op],v)); continue
        if op==0x45:
            raw=u16(); vid=struct.unpack_from('<I',buf,pos)[0]; pos+=4
            out.append((p0,'pop',names[vid] if vid<len(names) else hex(vid))); continue
        if op==0x9E: out.append((p0,'popz',t1)); continue
        if op==0x9C: out.append((p0,'ret',t1)); continue
        if op==0x86: out.append((p0,'dup',t1,b0,b1)); continue
        if op==0x07: out.append((p0,'conv',t1,t2)); continue
        if op in (8,9,10,11,12,13,14,15,16,0x13,0x14,0x15): out.append((p0,'arith%02x'%op,t1,t2)); continue
        out.append((p0,'op%02x'%op,b0,b1,b2))
    return out
for tag,entry in (('textbox_create',0xaea51c),('loadbox',0xaea5a8),('obj_textbox_Create',0xaed050)):
    buf,loc,arg=code_bytes(entry)
    print('==',tag,'locals',loc,'args',arg,'len',len(buf))
    for ins in decode(buf)[:60]: print('  ',ins)
