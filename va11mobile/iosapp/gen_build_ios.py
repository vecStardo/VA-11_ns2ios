#!/usr/bin/env python3
# 从 dm/host/Makefile 实际展开的编译命令（make -n -B dmhost_m3）取宿主的源文件 / 头文件路径 / 宏 / 框架，生成 iOS 工程的构建输入，
# 不手抄列表：Makefile 一改，iOS 下次构建自动跟上（思路同 d2r-mobile 的 dm/ios/tools/gen_build.py，VA-11 版的差别在平台过滤）。
#   Gen/src/<扁平名>   源文件符号链接（排除 *_mac 命名的 Mac 专用源与 hle_egl.m，另补 hle_egl_ios.m；main.c 另链到 Gen/main/main.c）
#   stdout            xcconfig 行：HEADER_SEARCH_PATHS / OTHER_CFLAGS / DM_FRAMEWORKS（Cocoa 与 OpenGL 不上 iOS，换成 UIKit + OpenGLES）
# 用法：gen_build_ios.py <dm/host 目录> <Gen 目录> > <xcconfig 片段>
# Take the host's source files / header paths / macros / frameworks from the expanded compile command of dm/host/Makefile
# (make -n -B dmhost_m3) and generate the iOS project's build inputs, without hand-copying lists: when the Makefile
# changes, the next iOS build follows automatically (same idea as d2r-mobile's dm/ios/tools/gen_build.py; the VA-11
# differences are the platform filters).
#   Gen/src/<flat name>   symlinks to source files (Mac-only sources named *_mac and hle_egl.m are excluded and
#                         hle_egl_ios.m added; main.c is linked separately to Gen/main/main.c)
#   stdout            xcconfig lines: HEADER_SEARCH_PATHS / OTHER_CFLAGS / DM_FRAMEWORKS (Cocoa and OpenGL are not on
#                     iOS; replaced by UIKit + OpenGLES)
# Usage: gen_build_ios.py <dm/host dir> <Gen dir> > <xcconfig fragment>
import os, shlex, subprocess, sys

host, gen = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
out = subprocess.run(['make', '-s', '-n', '-B', '-C', host, 'dmhost_m3'], capture_output=True, text=True, check=True).stdout
line = next((l for l in out.splitlines() if l.lstrip().startswith('clang')), None)
if not line:
    sys.exit('Makefile 展开的命令里没有 clang 行')
toks = shlex.split(line)

srcs, incs, defs, fws = [], [], [], []
i = 0
while i < len(toks):
    t = toks[i]
    if t == '-framework':
        fws.append(toks[i + 1]); i += 2; continue
    if t.startswith('-I'):
        # -I. / -I../gfx/nvn/include 都相对 host 目录 | both -I. and relative -I... are relative to the host directory
        incs.append(os.path.normpath(os.path.join(host, t[2:])))
    elif t.startswith('-D'):
        defs.append(t)
    elif t.endswith(('.c', '.m', '.S')):
        srcs.append(os.path.normpath(os.path.join(host, t)))
    i += 1
assert srcs, '编译命令里没有源文件'

# 平台过滤：Mac 专用源按 *_mac 命名；hle_egl.m 是 Mac 的 GL 垫片，iOS 用 hle_egl_ios.m。
# Platform filter: Mac-only sources follow the *_mac naming; hle_egl.m is the Mac GL shim, iOS uses hle_egl_ios.m.
def is_mac_only(path):
    stem = os.path.splitext(os.path.basename(path))[0]
    return stem.endswith('_mac') or os.path.basename(path) == 'hle_egl.m'

root = os.path.dirname(host)
# 每次重建符号链接目录（只清链接，不碰别的生成物） | Rebuild the symlink directories every time (only links, no other generated files)
import shutil
for sub in ('src', 'main'):
    d = f'{gen}/{sub}'
    if os.path.isdir(d) and not os.path.islink(d):
        shutil.rmtree(d)
    os.makedirs(d, exist_ok=True)

dirs = []
picked = []
for s in srcs:
    if s in picked:                   # Makefile 显式列与通配重叠时去重 | de-duplicate when the explicit list overlaps a wildcard
        continue
    picked.append(s)
    if is_mac_only(s):
        continue
    d = os.path.dirname(s)
    if d not in dirs: dirs.append(d)
    if os.path.basename(s) == 'main.c' and d == host:
        os.symlink(s, f'{gen}/main/main.c'); continue
    flat = os.path.relpath(s, root).replace('/', '__')
    os.symlink(s, f'{gen}/src/{flat}')
# iOS 的 GL 垫片（不在 Makefile 的 SRC 里） | the iOS GL shim (not in the Makefile's SRC)
if os.path.join(host, 'hle_egl_ios.m') not in picked:
    os.symlink(os.path.join(host, 'hle_egl_ios.m'), f'{gen}/src/host__hle_egl_ios.m')
    dirs.append(host)

# 宏：去掉 APP_NAME（只有 Mac App 形态的 app_mac.m 用，且值里带空格，xcconfig 里不好写）
# Macros: drop APP_NAME (used only by app_mac.m in Mac App form, and its value contains spaces that are awkward in xcconfig)
defs = [d for d in defs if not d.startswith('-DAPP_NAME')]

# 框架：Cocoa / OpenGL 不上 iOS；补 UIKit / OpenGLES（EGL 垫片与窗口都要）。
# Frameworks: Cocoa / OpenGL are not on iOS; add UIKit / OpenGLES (needed by the EGL shim and the window).
fw_keep = [f for f in fws if f not in ('Cocoa', 'OpenGL')]
for extra in ('UIKit', 'OpenGLES', 'CoreGraphics'):
    if extra not in fw_keep: fw_keep.append(extra)

searched = []
for d in incs + dirs:
    if d not in searched: searched.append(d)
print('HEADER_SEARCH_PATHS = $(inherited) ' + ' '.join(f'"{d}"' for d in searched))
print('OTHER_CFLAGS = $(inherited) ' + ' '.join(defs))
print('DM_FRAMEWORKS = ' + ' '.join(f'-framework {f}' for f in fw_keep))
