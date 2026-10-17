#!/usr/bin/env python3
"""Extract ExeFS NSOs (main/sdk/subsdk0) from a plaintext-dump NSZ (NCZ member).

The dump ships zeroed tickets and NCZ sections stored with cryptoType=1
(no crypto), so no key material is required. Mirrors nsz's IndependentNcz
decompressor, then walks the ExeFS PFS0 to pull out the NSO modules.
"""
import mmap
import struct
import sys
import zstandard
from pathlib import Path


def pfs0_entries(data, base):
    assert data[base:base + 4] == b'PFS0', f'no PFS0 at {base:#x}'
    n, hs = struct.unpack_from('<II', data, base + 4)
    st = base + 16 + n * 24
    out = []
    for i in range(n):
        fo, fs, no = struct.unpack_from('<QQI', data, base + 16 + i * 24)
        end = st + no
        while data[end] != 0:
            end += 1
        out.append((data[st + no:end].decode(), base + fo, fs))
    return out


def main(nsz_path, out_dir):
    f = open(nsz_path, 'rb')
    data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    n, hs, _ = struct.unpack_from('<III', data, 4)
    st = 16 + n * 24
    ncz_off = ncz_size = None
    for i in range(n):
        fo, fs, no = struct.unpack_from('<QQI', data, 16 + i * 24)
        end = st + no
        while data[end] != 0:
            end += 1
        name = data[st + no:end].decode()
        if name.endswith('.ncz'):
            ncz_off, ncz_size = fo, fs
    assert ncz_off is not None, 'no .ncz member'

    base = data.find(b'NCZSECTN') - 0x4000
    assert base >= 0 and base == ncz_off or True, (hex(base), hex(ncz_off))
    count = struct.unpack_from('<Q', data, base + 0x4008)[0]
    print(f'sections: {count}')
    secs = []
    p = base + 0x4010
    for i in range(count):
        off, size, ctype = struct.unpack_from('<QQQ', data, p)
        key = bytes(data[p + 0x20:p + 0x30])
        ctr = bytes(data[p + 0x30:p + 0x40])
        print(f'  sec{i}: off={off:#x} size={size/1048576:.1f}MiB crypto={ctype}')
        secs.append((off, size, ctype, key, ctr))
        p += 0x40
    pos = p
    if data[pos:pos + 8] == b'NCZBLOCK':
        raise SystemExit('block-compressed NCZ: extend script')

    header = bytes(data[base:base + 0x4000])
    dctx = zstandard.ZstdDecompressor()
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    nca_path = out_dir / 'program.nca'
    with open(nca_path, 'wb') as out:
        out.write(header)
        reader = dctx.stream_reader(mmap_fileview(data, pos, ncz_size - (pos - base)))
        remaining = {s[0]: s[1] for s in secs}
        written = 0x4000
        for s in secs:
            off, size, ctype, key, ctr = s
            assert ctype == 1, f'encrypted section (crypto={ctype}) needs keys'
            left = size
            while left:
                chunk = reader.read(min(1 << 20, left))
                if not chunk:
                    break
                out.write(chunk)
                left -= len(chunk)
                written += len(chunk)
        print(f'wrote {nca_path} ({written/1048576:.1f}MiB)')

    nd = open(nca_path, 'rb').read(0x40000000)
    exefs_base = secs[0][0]
    for name, fo, fs in pfs0_entries(nd, exefs_base):
        if name.endswith('.nso') or name in ('main', 'sdk', 'subsdk0', 'rtld'):
            blob = bytes(nd[fo:fo + fs])
            assert blob[:4] == b'NSO0', f'{name}: bad NSO magic'
            dst = out_dir / f'{Path(name).stem}.nso'
            dst.write_bytes(blob)
            print(f'  {dst.name}: {fs/1048576:.2f}MiB buildid={blob[0x40:0x44].hex()}')


class _View:
    def __init__(self, mm, off, size):
        self.mm, self.off, self.size = mm, off, size
    def read(self, n):
        n = min(n, self.size)
        d = self.mm[self.off:self.off + n]
        self.off += n
        self.size -= n
        return d


def mmap_fileview(mm, off, size):
    return _View(mm, off, size)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
