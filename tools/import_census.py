#!/usr/bin/env python3
"""List the modules' nn::* imports that no host HLE hook names (a porting gap census).

Mirrors nxnative's docs/agents: "list main's nn:: imports that no host hook names";
each unresolved-looking import is a candidate for a service the host must answer.
Reads the decompressed NSO payloads (NSO0) and the HLE_FORCE tables in dm/host/*.c.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOST = ROOT / 'va11mobile' / 'dm' / 'host'


def hle_names():
    names = set()
    for f in HOST.glob('*.c'):
        for m in re.finditer(r'HLE_FORCE\w*\(\s*"([^"]+)"', f.read_text(errors='ignore')):
            names.add(m.group(1))
    return names


def module_imports(path):
    d = Path(path).read_bytes()
    # NSO0: header 0x100; text at 0x100 (compressed)! Search the decompressed payload for symbol names instead.
    out = set()
    for m in re.finditer(rb'_ZN2nn[A-Za-z0-9_.$]+', d):
        out.add(m.group().decode('latin1'))
    return out


def main(paths):
    names = hle_names()
    print(f'host hooks: {len(names)}')
    for p in paths:
        imps = module_imports(p)
        missing = sorted(i for i in imps if i not in names)
        print(f'\n== {Path(p).name}: imports {len(imps)}, not named by any hook {len(missing)}')
        for s in missing:
            print('  ', s)


if __name__ == '__main__':
    main(sys.argv[1:])
