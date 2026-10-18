import struct
d=open('orig/game.win','rb').read()
def s_ptr(p):
    out=bytearray()
    for i in range(160):
        c=d[p+i]
        if c<0x20 or c>0x7e: break
        out.append(c)
    return out.decode('ascii','replace')
vari=0xafaba0; vcnt=struct.unpack_from('<I',d,vari+8)[0]
pos=vari+20; vars_=[]
for i in range(vcnt):
    name,it,vid,occ,first=struct.unpack_from('<IIIII',d,pos)
    vars_.append((s_ptr(name),it,occ,first)); pos+=20
# 建出现位置 -> 变量名
occ_map={}
for nm,it,occ,first in vars_:
    if occ<1 or first==0: continue
    p=first+4
    for k in range(min(occ,64)):
        off=struct.unpack_from('<I',d,p)[0]
        occ_map[p]=(nm,it)
        o=off & 0x07FFFFFF
        if o<1: break
        p=p+o
print('occ_map size',len(occ_map))
def code_bytes(entry):
    name,ln,loc,arg,f1,_=struct.unpack_from('<IIHHII',d,entry)
    if f1>=0x80000000: f1-=0x100000000
    a=entry+f1
    return a,d[a:a+ln],loc,arg
def decode(base,buf):
    p=0; out=[]
    while p+4<=len(buf):
        w=struct.unpack_from('<I',buf,p)[0]; op=w>>24
        b0=w&0xFF; b1=(w>>8)&0xFF; b2=(w>>16)&0xFF; t1=b2&0xF; t2=b2>>4
        start=p; p+=4
        u16v=b0|(b1<<8)
        def varref():
            nonlocal p
            wp=p; p+=4
            nm=occ_map.get(base+wp)
            return nm[0] if nm else '?%d'%wp
        if op==0x84: out.append((start,'pushim',u16v)); continue
        if op in (0xC1,0xC2,0xC3):
            nm=varref(); out.append((start,{0xC1:'pushloc',0xC2:'pushglb',0xC3:'pushbltn'}[op],nm)); continue
        if op==0xC0:
            if t1==15: out.append((start,'push.i16',u16v))
            elif t1==2: v=struct.unpack_from('<i',buf,p)[0]; p+=4; out.append((start,'push.i32',v))
            elif t1 in (3,0): p+=8; out.append((start,'push.dbl','<8>'))
            elif t1==6: sid=struct.unpack_from('<I',buf,p)[0]; p+=4; out.append((start,'push.str',sid))
            elif t1==5: out.append((start,'push.var',varref()))
            elif t1==4: p+=4; out.append((start,'push.bool','<4>'))
            else: out.append((start,'push?',t1))
            continue
        if op==0xD9:
            if p+4>len(buf): out.append((start,'call<eof>',)); break
            argc=u16v; fid=struct.unpack_from('<I',buf,p)[0]; p+=4
            out.append((start,'call',fid,argc)); continue
        if op==0x99: out.append((start,'callvar',u16v)); continue
        if op in (0xB6,0xB7,0xB8,0xBA,0xBB):
            v=b0|(b1<<8)|(b2<<16)
            if v&0x800000: v-=0x1000000
            out.append((start,{0xB6:'jmp',0xB7:'jt',0xB8:'jf',0xBA:'pushenv',0xBB:'popenv'}[op],v)); continue
        if op==0x45:
            if t1==15: out.append((start,'popswap',)); continue
            out.append((start,'pop',varref())); continue
        if op==0x9E: out.append((start,'popz',)); continue
        if op==0x9C: out.append((start,'ret',)); continue
        if op==0x86: out.append((start,'dup',t1,b0,b1)); continue
        if op==0x07: out.append((start,'conv',t1,t2)); continue
        if op in (8,9,10,11,12,13,14,15,16,0x13,0x14): out.append((start,'arith%02x'%op,t1,t2)); continue
        if op==0x15: out.append((start,'cmp',b1,t1,t2)); continue
        if op==0xA0: out.append((start,'opa0',w&0xFFFFFF)); continue
        out.append((start,'op%02x'%op,w&0xFFFFFF))
    return out
for tag,entry in (('textbox_create',0xaea51c),('loadbox',0xaea5a8)):
    base,buf,loc,arg=code_bytes(entry)
    print('==',tag,'base',hex(base),'locals',loc,'len',len(buf))
    for ins in decode(base,buf): print('  ',ins)
