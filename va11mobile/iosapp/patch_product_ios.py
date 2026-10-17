#!/usr/bin/env python3
# 出包期的产物补丁：把两条 VA-11 运行期补丁落到给 iOS 内嵌用的产物副本上。
# 为什么不在宿主装载时改：iOS 不允许改已签名的代码页（Mac 宿主 map_image 里 memcpy 改 RET 的做法在 iOS 上会崩，
# 真机还会被 AMFI 判签名无效）。补丁本身是两条 udf 空洞补 RET（与 dm/host/loader.c 的 DM_FOREIGN_GAME 段一致）：
#   main+0xd476d8  show_message 的「显示」函数指针指向的 udf 空洞 → RET（空操作对话框，GML 继续）
#   sdk +0xc0764   AbortImpl 调用方放的 udf（语义上永不返回）→ RET（宿主 AbortImpl 返回时落回调用方）
# 幂等：已经是 RET 就跳过；不是 udf/ RET 就报错退出（构建不符要响亮）。
# 用法：patch_product_ios.py <产物目录> <暂存目录>
# Build-time product patch: apply the two VA-11 run-time patches to the copy of the build output embedded into the iOS app.
# Why not at host load time: iOS forbids writing signed code pages (the Mac host map_image's memcpy-to-RET would crash on
# iOS, and on a real device AMFI would call the signature invalid). The patches themselves are two udf holes turned into
# RET (same as the DM_FOREIGN_GAME section of dm/host/loader.c):
#   main+0xd476d8  the udf hole the show_message "show" function pointer points at -> RET (no-op dialog, GML continues)
#   sdk +0xc0764   the udf the AbortImpl caller planted (semantically never returns) -> RET (host AbortImpl returns to caller)
# Idempotent: already RET is skipped; anything that is neither udf nor RET aborts (a build mismatch must be loud).
# Usage: patch_product_ios.py <product dir> <staging dir>
import os, shutil, sys

src, dst = sys.argv[1], sys.argv[2]
RET = bytes.fromhex('c0035fd6')   # ret
UDF = bytes.fromhex('00000000')   # udf #0
PATCH = [('main', 0xd476d8, 'show_message 的显示函数 udf 空洞 → RET'),
         ('sdk', 0xc0764, 'AbortImpl 调用方的 udf → RET')]

os.makedirs(dst, exist_ok=True)
for name in os.listdir(src):
    s, d = os.path.join(src, name), os.path.join(dst, name)
    if os.path.isdir(s):
        shutil.copytree(s, d, dirs_exist_ok=True)
    else:
        shutil.copy2(s, d)

for mod, off, why in PATCH:
    p = os.path.join(dst, f'{mod}.patched.bin')
    with open(p, 'r+b') as f:
        f.seek(off)
        cur = f.read(4)
        if cur == RET:
            print(f'[patch] {mod}+{off:#x}: 已是 RET，跳过（{why}）')
            continue
        if cur != UDF:
            sys.exit(f'[patch] 🔴 {mod}+{off:#x} 原字节 {cur.hex()} 既不是 udf 也不是 RET（产物构建号不符？）')
        f.seek(off)
        f.write(RET)
    print(f'[patch] {mod}+{off:#x}: udf → RET（{why}）')
