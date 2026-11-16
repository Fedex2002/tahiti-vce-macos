#!/usr/bin/env python3
"""gva.py: a tiny disassembler for one Mach-O image, either inside a dyld shared cache sub-file (x86_64)
or as a standalone Mach-O file. Needs capstone (pip install capstone / apt install python3-capstone).

Shared cache image (find the image's __TEXT address in dyld_shared_cache_x86_64.map, and use the sub-file
that contains it):
  gva.py <cache-subfile> <image_base_hex> info
  gva.py <cache-subfile> <image_base_hex> str <regex>             C strings of the image matching the regex
  gva.py <cache-subfile> <image_base_hex> xref <vmaddr_hex>...    instructions that reference those addresses
  gva.py <cache-subfile> <image_base_hex> func <vmaddr_hex> [max] disassemble the function containing the address
  gva.py <cache-subfile> <image_base_hex> sym <regex>             symbols matching the regex
  gva.py <cache-subfile> <image_base_hex> bytes <vmaddr_hex> <n>

Standalone Mach-O (e.g. AMDRadeonVADriver): pass the literal word "macho" instead of the image base:
  gva.py AMDRadeonVADriver macho sym 'AvdCapability'
  gva.py AMDRadeonVADriver macho func 7ffa1cb80598

Pointers inside the shared cache are decoded with the slide-info-v2 parameters used by the macOS 26 x86_64
cache (delta mask 0x00FFFF0000000000, value_add 0x7FF800000000).
"""
import re, struct, sys, mmap
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
from capstone.x86 import X86_OP_MEM, X86_OP_IMM, X86_REG_RIP

class Cache:
    def __init__(self, path):
        self.f = open(path, 'rb')
        self.m = mmap.mmap(self.f.fileno(), 0, access=mmap.ACCESS_READ)
        moff, mcnt = struct.unpack_from('<II', self.m, 0x10)
        self.maps = [struct.unpack_from('<QQQII', self.m, moff + i * 32) for i in range(mcnt)]
    def off(self, vm):
        for a, s, fo, _, _ in self.maps:
            if a <= vm < a + s: return fo + (vm - a)
        return None
    def rd(self, vm, n):
        o = self.off(vm)
        return None if o is None else self.m[o:o + n]
    def ptr(self, vm):
        d = self.rd(vm, 8)
        if not d or len(d) < 8: return None
        raw = struct.unpack('<Q', d)[0] & ~0x00FFFF0000000000
        return raw + 0x7FF800000000 if raw and raw < 0x7FF800000000 else raw
    def cstr(self, vm, lim=400):
        o = self.off(vm)
        if o is None: return None
        e = self.m.find(b'\0', o, o + lim)
        if e < 0: return None
        try: return self.m[o:e].decode('utf-8')
        except UnicodeDecodeError: return None

class MachO(Cache):
    """Standalone Mach-O (not a cache): the mappings are its segments."""
    def __init__(self, path):
        self.f = open(path, 'rb')
        self.m = mmap.mmap(self.f.fileno(), 0, access=mmap.ACCESS_READ)
        ncmds = struct.unpack_from('<I', self.m, 16)[0]
        self.maps = []; p = 32; self.base = None
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', self.m, p)
            if cmd == 0x19:
                name = self.m[p + 8:p + 24].rstrip(bytes(1)).decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', self.m, p + 24)
                self.maps.append((vmaddr, filesize, fileoff, 0, 0))
                if name == '__TEXT': self.base = vmaddr
            p += size
    def ptr(self, vm):
        d = self.rd(vm, 8)
        if not d or len(d) < 8: return None
        raw = struct.unpack('<Q', d)[0]
        if raw >> 63: return None  # bind
        v = raw & 0xFFFFFFFFF
        return v

class Image:
    def __init__(self, c, base):
        self.c, self.base = c, base
        magic, _, _, _, ncmds, _, _, _ = struct.unpack_from('<IiiIIIII', c.rd(base, 32))
        assert magic == 0xFEEDFACF, hex(magic)
        self.segs, self.sects, self.syms, self.fstarts = {}, {}, {}, []
        self.res, self.imp, dys, names = {}, {}, None, []
        p = base + 32
        symtab = fs = None
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', c.rd(p, 8))
            d = c.rd(p, size)
            if cmd == 0x19:  # LC_SEGMENT_64
                name = d[8:24].rstrip(b'\0').decode()
                vmaddr, vmsize, fileoff, filesize, _, _, nsects, _ = struct.unpack_from('<QQQQiiII', d, 24)
                self.segs[name] = (vmaddr, vmsize, fileoff)
                for i in range(nsects):
                    s = d[72 + i * 80: 72 + (i + 1) * 80]
                    sn = s[:16].rstrip(b'\0').decode()
                    addr, ssize = struct.unpack_from('<QQ', s, 32)
                    self.sects[f'{name},{sn}'] = (addr, ssize)
                    self.res[f'{name},{sn}'] = struct.unpack_from('<II', s, 68)
            elif cmd == 0x2: symtab = struct.unpack_from('<IIII', d, 8)
            elif cmd == 0x26: fs = struct.unpack_from('<II', d, 8)
            elif cmd == 0xB: dys = struct.unpack_from('<II', d, 56)
            p += size
        le_vm, _, le_fo = self.segs['__LINKEDIT']
        lvm = lambda fo: le_vm + (fo - le_fo)
        if symtab:
            symoff, nsyms, stroff, strsize = symtab
            for i in range(nsyms):
                e = c.rd(lvm(symoff) + i * 16, 16)
                if e is None: break
                strx, typ, sect, desc, val = struct.unpack('<IBBHQ', e)
                n = c.cstr(lvm(stroff) + strx)
                names.append(n)
                if typ & 0xE0 or not val: continue
                if n: self.syms.setdefault(val, n)
        if dys and dys[1]:
            ind = struct.unpack(f'<{dys[1]}I', c.rd(lvm(dys[0]), dys[1] * 4))
            for sn, (a, sz) in self.sects.items():
                r1, r2 = self.res[sn]
                step = 6 if sn.endswith('__stubs') else 8 if sn.endswith(('__got', '__la_symbol_ptr', '__auth_got')) else 0
                if not step: continue
                for i in range(sz // step):
                    if r1 + i < len(ind) and ind[r1 + i] < len(names) and names[ind[r1 + i]]: self.imp[a + i * step] = names[ind[r1 + i]]
        if fs:
            data = c.rd(lvm(fs[0]), fs[1]); a = self.segs['__TEXT'][0]; i = 0
            while i < len(data):
                v = sh = 0
                while True:
                    b = data[i]; i += 1; v |= (b & 0x7F) << sh; sh += 7
                    if not b & 0x80: break
                if v == 0: break
                a += v; self.fstarts.append(a)
        self.text = self.sects['__TEXT,__text']
        if not self.fstarts: self.fstarts = sorted(a for a in self.syms if self.text[0] <= a < self.text[0] + self.text[1])
        self.md = Cs(CS_ARCH_X86, CS_MODE_64); self.md.detail = True
    def fn_of(self, vm):
        import bisect
        i = bisect.bisect_right(self.fstarts, vm) - 1
        s = self.fstarts[i]; e = self.fstarts[i + 1] if i + 1 < len(self.fstarts) else self.text[0] + self.text[1]
        return s, e
    def name(self, vm):
        if vm in self.syms: return self.syms[vm]
        if vm in self.imp: return self.imp[vm]
        return None
    def describe(self, vm):
        n = self.name(vm)
        if n: return n
        for sn, (a, s) in self.sects.items():
            if a <= vm < a + s:
                if 'cstring' in sn or 'oslogstring' in sn or '__const' in sn:
                    t = self.c.cstr(vm)
                    if t and len(t) >= 2 and all(31 < ord(ch) < 127 or ch in '\n\t' for ch in t[:60]): return f'"{t[:110]}"'
                if 'cfstring' in sn:
                    t = self.c.cstr(self.c.ptr(vm + 16) or 0)
                    return f'@"{t}"' if t else sn
                return f'<{sn}+{vm - a:#x}>'
        return None
    def targets(self, ins):
        out = []
        for op in ins.operands:
            if op.type == X86_OP_MEM and op.mem.base == X86_REG_RIP: out.append(ins.address + ins.size + op.mem.disp)
            elif op.type == X86_OP_IMM and op.imm > 0x10000: out.append(op.imm & 0xFFFFFFFFFFFFFFFF)
        return out
    def disasm(self, s, e):
        code = self.c.rd(s, e - s)
        for ins in self.md.disasm(code, s):
            note = []
            for t in self.targets(ins):
                d = self.describe(t)
                if d: note.append(d)
                elif ins.mnemonic.startswith(('call', 'j')) and not (self.text[0] <= t < self.text[0] + self.text[1]): note.append(f'ext {t:#x}')
            yield ins, ' ; '.join(note)

def main():
    if sys.argv[2] == 'macho':
        c = MachO(sys.argv[1]); img = Image(c, c.base)
    else:
        c = Cache(sys.argv[1]); img = Image(c, int(sys.argv[2], 16))
    cmd = sys.argv[3]
    if cmd == 'info':
        for k, v in img.segs.items(): print(k, [hex(x) for x in v])
        for k, v in img.sects.items(): print('  ', k, hex(v[0]), hex(v[1]))
        print('syms', len(img.syms), 'funcs', len(img.fstarts))
    elif cmd == 'str':
        rx = re.compile(sys.argv[4])
        for sn, (a, s) in img.sects.items():
            if not ('cstring' in sn or 'oslogstring' in sn): continue
            data = c.rd(a, s); p = 0
            for part in data.split(b'\0'):
                t = part.decode('utf-8', 'replace')
                if t and rx.search(t): print(f'{a + p:#x} {t!r}')
                p += len(part) + 1
    elif cmd == 'sym':
        rx = re.compile(sys.argv[4])
        for a, n in sorted(img.syms.items()):
            if rx.search(n): print(f'{a:#x} {n}')
    elif cmd == 'xref':
        want = {int(x, 16) for x in sys.argv[4:]}
        for i, s in enumerate(img.fstarts):
            if not (img.text[0] <= s < img.text[0] + img.text[1]): continue
            e = img.fstarts[i + 1] if i + 1 < len(img.fstarts) else img.text[0] + img.text[1]
            for ins in img.md.disasm(c.rd(s, e - s), s):
                for t in img.targets(ins):
                    if t in want: print(f'{ins.address:#x} in fn {s:#x} {img.name(s) or ""}: {ins.mnemonic} {ins.op_str}  -> {t:#x}')
    elif cmd == 'func':
        vm = int(sys.argv[4], 16); s, e = img.fn_of(vm)
        mx = int(sys.argv[5]) if len(sys.argv) > 5 else 100000
        print(f'; fn {s:#x}..{e:#x} {img.name(s) or ""}')
        for n, (ins, note) in enumerate(img.disasm(s, e)):
            if n >= mx: break
            mark = '>>' if ins.address <= vm < ins.address + ins.size else '  '
            print(f'{mark}{ins.address:#x}: {ins.mnemonic:8s}{ins.op_str}' + (f'    ; {note}' if note else ''))
    elif cmd == 'bytes':
        print(c.rd(int(sys.argv[4], 16), int(sys.argv[5])).hex())

if __name__ == '__main__': main()
