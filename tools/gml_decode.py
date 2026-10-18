#!/usr/bin/env python3
"""GML 字节码解码器（VA-11 HALL-A Switch 版 data.win）。

用法: VA11_GAME_WIN=/path/game.win python3 tools/gml_decode.py <脚本名> [条数]
脚本名例如 gml_Script_textbox_create / gml_Object_async_init_Create_0。

要点（逆向得到）：
- CODE 条目 20 字节：{name_ptr, length, locals(u16), args(u16), bytecode_rel(i32), reserved}
  bytecode 地址 = 条目地址 + bytecode_rel；
- 指令 4 字节小端字，操作码在最高字节；变量/函数引用的第二个字在 release 版里是
  「下一个出现位置的偏移」，真正的身份要用 VARI/FUNC 的出现位置表反查。
"""
import struct
import sys
import os

GAME = os.environ.get("VA11_GAME_WIN", os.path.expanduser("~/va11-work/orig/game.win"))
d = open(GAME, "rb").read()

CODE_OFF = 0x965b70
VARI_OFF = 0xafaba0
FUNC_OFF = 0xb1e990
STRG_OFF = 0xb301c0


def s_ptr(p):
    out = bytearray()
    for i in range(200):
        c = d[p + i]
        if c < 0x20 or c > 0x7E:
            break
        out.append(c)
    return out.decode("ascii", "replace")


def s_idx(i):
    p = STRG_OFF + 8 + 4 * i
    o = struct.unpack_from("<I", d, p)[0]
    ln = struct.unpack_from("<I", d, o)[0]
    if ln <= 0 or ln > 300:
        return "?"
    return d[o + 4 : o + 4 + ln].decode("utf-8", "replace")


def build_occ_map(chunk_off, entry_size, header, nfields):
    """VARI/FUNC 的「出现位置 -> 名字」映射。"""
    cnt = struct.unpack_from("<I", d, chunk_off + 8)[0]
    pos = chunk_off + header
    entries = []
    for _ in range(cnt):
        if nfields == 5:
            name, _it, _vid, occ, first = struct.unpack_from("<IIIII", d, pos)
        else:
            name, occ, first = struct.unpack_from("<III", d, pos)
        entries.append((s_ptr(name), occ, first))
        pos += entry_size
    m = {}
    for nm, occ, first in entries:
        if occ < 1 or first == 0:
            continue
        p = first + 4
        for _ in range(min(occ, 4000)):
            if p + 4 > len(d):
                break
            off = struct.unpack_from("<I", d, p)[0]
            m.setdefault(p, nm)
            q = off & 0x07FFFFFF
            if q < 1:
                break
            p += q
    return m


VARS = build_occ_map(VARI_OFF, 20, 20, 5)   # VARI: 8 字节 chunk 头 + 12 字节 ModernHeader
FUNCS = build_occ_map(FUNC_OFF, 12, 12, 3)  # FUNC: 8 字节 chunk 头 + 4 字节 count
CODE_COUNT = struct.unpack_from("<I", d, CODE_OFF + 8)[0]
CODE_ARR = CODE_OFF + 12


def entry_by_name(name):
    for i in range(CODE_COUNT):
        e = struct.unpack_from("<I", d, CODE_ARR + 4 * i)[0]
        nm, ln, loc, arg, f1, _ = struct.unpack_from("<IIHHII", d, e)
        if s_ptr(nm) == name:
            if f1 >= 0x80000000:
                f1 -= 0x100000000
            return e + f1, ln, loc, arg
    return None


def decode(base, buf):
    p = 0
    out = []
    while p + 4 <= len(buf):
        w = struct.unpack_from("<I", buf, p)[0]
        op = w >> 24
        b0, b1, b2 = w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF
        t1, t2 = b2 & 0xF, b2 >> 4
        st = p
        p += 4

        def operand_name(m):
            nonlocal p
            wp = p
            p += 4
            return m.get(base + wp, "?%d" % wp)

        if op == 0x84:
            out.append((st, "pushim", b0 | (b1 << 8)))
            continue
        if op in (0xC1, 0xC2, 0xC3):
            nm = operand_name(VARS)
            out.append((st, {0xC1: "pushloc", 0xC2: "pushglb", 0xC3: "pushbltn"}[op], nm))
            continue
        if op == 0xC0:
            if t1 == 15:
                out.append((st, "push.i16", b0 | (b1 << 8)))
            elif t1 == 2:
                v = struct.unpack_from("<i", buf, p)[0]
                p += 4
                out.append((st, "push.i32", v))
            elif t1 in (3, 0):
                p += 8
                out.append((st, "push.dbl"))
            elif t1 == 4:
                p += 4
                out.append((st, "push.bool"))
            elif t1 == 6:
                sid = struct.unpack_from("<I", buf, p)[0]
                p += 4
                out.append((st, "push.str", s_idx(sid)))
            elif t1 == 5:
                out.append((st, "push.var", operand_name(VARS)))
            else:
                out.append((st, "push?", t1))
            continue
        if op == 0xD9:
            argc = b0 | (b1 << 8)
            if p + 4 > len(buf):
                break
            out.append((st, "call", operand_name(FUNCS), argc))
            continue
        if op == 0x45:
            out.append((st, "pop", operand_name(VARS)))
            continue
        if op in (0xB6, 0xB7, 0xB8, 0xBA, 0xBB):
            v = b0 | (b1 << 8) | (b2 << 16)
            if v & 0x800000:
                v -= 0x1000000
            out.append((st, {0xB6: "jmp", 0xB7: "jt", 0xB8: "jf", 0xBA: "pushenv", 0xBB: "popenv"}[op], v))
            continue
        if op == 0x9E:
            out.append((st, "popz"))
            continue
        if op == 0x9C:
            out.append((st, "ret"))
            continue
        if op == 0x07:
            out.append((st, "conv", t1, t2))
            continue
        if op == 0x86:
            out.append((st, "dup", t1))
            continue
        if op in (8, 9, 10, 11, 12, 13, 14, 15, 16, 0x13, 0x14):
            out.append((st, "arith%02x" % op))
            continue
        if op == 0x15:
            out.append((st, "cmp"))
            continue
        out.append((st, "op%02x" % op))
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    name = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    r = entry_by_name(name)
    if not r:
        print("找不到脚本:", name)
        return 2
    base, ln, loc, arg = r
    print("== %s bytecode=%#x len=%d locals=%d args=%d" % (name, base, ln, loc, arg))
    for ins in decode(base, d[base : base + ln])[:limit]:
        print("  %04x %s" % (ins[0], " ".join(str(x) for x in ins[1:])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
