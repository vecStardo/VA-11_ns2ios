#!/usr/bin/env python3
"""从 NSZ 明文 dump 解出的 program.nca 里取出**未汉化原版** game.win。

背景 / Why: 汉化补丁只提供替换用的 romfs/game.win；做「补丁 vs 原版」对照时需要原版。
NSZ 明文 dump（NCZ 段落 cryptoType=1，无需 keys）解出的 program.nca 里，romfs 的 data 段
以 GameMaker 容器头 `FORM` + 4 字节长度 + `GEN8` 开头，整段就是 game.win。
本脚本按这个特征扫描并落盘，输出 SHA-256 供对照。

用法 / Usage:
  python3 tools/extract_original_game_win.py ~/va11-work/program.nca ~/va11-work/orig/game.win
"""
import hashlib
import struct
import sys

def main(nca_path: str, out_path: str) -> None:
    with open(nca_path, "rb") as f:
        data = f.read()
    # GameMaker 容器：FORM <len:u32le> GEN8。先找 GEN8，再回退 8 字节确认 FORM 与长度。
    hits = []
    idx = 0
    while True:
        i = data.find(b"GEN8", idx)
        if i < 0:
            break
        idx = i + 4
        if i < 8 or data[i - 8:i - 4] != b"FORM":
            continue
        size = struct.unpack_from("<I", data, i - 4)[0]   # 长度字段是小端 | the length field is little-endian
        end = i - 4 + size
        if 0 < size <= len(data) - (i - 4) and end <= len(data):
            hits.append((i - 8, size + 8))
    if not hits:
        sys.exit("没找到 FORM/GEN8 容器：确认 program.nca 是明文 dump（cryptoType=1）")
    # 取最大的那个（romfs 的 game.win 是整包里最大的 GameMaker 容器）
    off, length = max(hits, key=lambda h: h[1])
    blob = data[off:off + length]
    with open(out_path, "wb") as f:
        f.write(blob)
    print(f"game.win: {length} 字节 @ {off:#x}")
    print(f"sha256: {hashlib.sha256(blob).hexdigest()}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
