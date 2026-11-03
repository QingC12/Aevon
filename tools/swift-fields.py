# -*- coding: utf-8 -*-
"""Swift 类型/字段表还原（从 __swift5_types 驱动）。

为什么不从 __swift5_fieldmd 直接扫：那是一个没有自描述边界的记录流，靠猜
kind/recordSize 往前走，一旦错一格后面全歪。`__swift5_types` 是 int32 数组，
每格是「相对本格、指向类型描述符」的偏移，描述符里再给出一个相对偏移指向
字段表。有明确的入口，就不需要猜。

Swift ABI 用到的三段：

  ContextDescriptor     u32 flags, i32 parent
  TypeContextDescriptor 再接 i32 name, i32 accessFunction, i32 fields
  FieldDescriptor        i32 mangled, i32 superclass, u16 kind, u16 recSize, u32 num

字段名的偏移相对的是**那条 FieldRecord 自己的虚拟地址**，不是描述符起点。
把这一格弄错，解出来的会是一串看起来像名字、实际是隔壁字段的垃圾。

用法：
    python tools/swift-fields.py <dylib> [过滤子串]
"""
import struct
import sys

LC_SEGMENT_64 = 0x19

KIND = {0: "module", 1: "extension", 2: "anonymous", 3: "protocol",
        4: "class", 5: "struct", 6: "enum"}


def demangle(name):
    """把 _TtC6Stheno7RingEnv 这类名字还原成人看得懂的形式。

    只处理 _TtC（Swift class）与 _TtV（struct/enum 的值类型简写）两族，
    其余原样返回。不追求完整 demangle，够用来认类就行。
    """
    if not name:
        return name
    if name.startswith("_TtC"):
        rest = name[4:]
        out = []
        index = 0
        while index < len(rest):
            digits = ""
            while index < len(rest) and rest[index].isdigit():
                digits += rest[index]
                index += 1
            if not digits:
                break
            length = int(digits)
            out.append(rest[index:index + length])
            index += length
        return ".".join(out) if out else name
    return name


class MachO:
    def __init__(self, data):
        data = self._slice(data)
        self.data = data
        if data[:4] != b"\xcf\xfa\xed\xfe":
            raise SystemExit("not a 64-bit little-endian Mach-O: %s"
                             % data[:4].hex())
        self.sections = {}
        self.ranges = []
        ncmds = struct.unpack_from("<I", data, 16)[0]
        off = 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", data, off)
            if cmd == LC_SEGMENT_64:
                nsects = struct.unpack_from("<I", data, off + 64)[0]
                body = off + 72
                for _ in range(nsects):
                    sect = data[body:body + 16].rstrip(b"\0").decode()
                    addr, ssize = struct.unpack_from("<QQ", data, body + 32)
                    foff = struct.unpack_from("<I", data, body + 48)[0]
                    if ssize:
                        self.sections[sect] = (addr, ssize, foff)
                        self.ranges.append((addr, ssize, foff))
                    body += 80
            off += size

    @staticmethod
    def _slice(data):
        if data[:4] != b"\xca\xfe\xba\xbe":
            return data
        count = struct.unpack_from(">I", data, 4)[0]
        pieces = []
        for index in range(count):
            at = 8 + index * 20
            cputype, cpusub, off, size = struct.unpack_from(">iiII", data, at)
            if cputype == 0x0100000c:
                pieces.append(data[off:off + size])
        for piece in pieces:
            if b"__swift5_types" in piece:
                return piece
        if not pieces:
            raise SystemExit("fat binary without an arm64 slice")
        return pieces[0]

    def to_file(self, vaddr):
        for addr, size, foff in self.ranges:
            if addr <= vaddr < addr + size:
                return foff + (vaddr - addr)
        return None

    def cstr(self, vaddr):
        at = self.to_file(vaddr)
        if at is None:
            return None
        end = self.data.find(b"\0", at)
        if end < 0 or end - at > 200:
            return None
        try:
            return self.data[at:end].decode("utf-8")
        except UnicodeDecodeError:
            return None


def fields_of(mo, fields_vaddr):
    """读一个 FieldDescriptor，返回 (kind, [字段名])。

    FieldRecord 的真实布局（母本实测，不是文档推测）：

        u32  flags
        i32  mangledTypeName   相对本格自身
        i32  fieldName         相对本格自身

    三格，字段名在**第 3 格**。按「fieldName 在最前」的常见写法读会得到一串
    常数 2（flags 的低位），而且不报错 —— 这是最费时间的一类错误：它有输出。
    """
    at = mo.to_file(fields_vaddr)
    if at is None:
        return None, []
    mangled_rel, super_rel, kind, rec_size, num = struct.unpack_from(
        "<iiHHI", mo.data, at)
    if not (12 <= rec_size <= 64) or not (0 < num <= 400) or kind > 7:
        return None, []
    out = []
    for index in range(num):
        rec_file = at + 16 + index * rec_size
        if rec_file + rec_size > len(mo.data):
            return None, []
        rec_vaddr = fields_vaddr + 16 + index * rec_size
        name_rel = struct.unpack_from("<i", mo.data, rec_file + 8)[0]
        if name_rel == 0:
            out.append("<unnamed>")
            continue
        out.append(mo.cstr(rec_vaddr + 8 + name_rel) or "<unreadable>")
    return kind, out


def main():
    path = sys.argv[1]
    needle = sys.argv[2] if len(sys.argv) > 2 else None
    mo = MachO(open(path, "rb").read())

    if "__swift5_types" not in mo.sections:
        raise SystemExit("no __swift5_types")
    ty_addr, ty_size, ty_off = mo.sections["__swift5_types"]

    total = ty_size // 4
    found = []
    for index in range(total):
        slot_vaddr = ty_addr + index * 4
        rel = struct.unpack_from("<i", mo.data, ty_off + index * 4)[0]
        desc_vaddr = slot_vaddr + rel
        desc_at = mo.to_file(desc_vaddr)
        if desc_at is None:
            continue
        flags = struct.unpack_from("<I", mo.data, desc_at)[0]
        type_kind = flags & 0x1F
        name_rel = struct.unpack_from("<i", mo.data, desc_at + 8)[0]
        name = demangle(mo.cstr(desc_vaddr + 8 + name_rel))
        fields_rel = struct.unpack_from("<i", mo.data, desc_at + 16)[0]
        fields = []
        if fields_rel:
            _, fields = fields_of(mo, desc_vaddr + 16 + fields_rel)
        found.append((name, KIND.get(type_kind, str(type_kind)), fields))

    print("types: %d (of %d slots)" % (len(found), total))
    shown = 0
    for name, kind, fields in found:
        blob = (name or "") + " " + " ".join(fields)
        if needle and needle.lower() not in blob.lower():
            continue
        shown += 1
        label = name or "<anonymous>"
        print("\n== %s  (%s, %d fields)" % (label, kind, len(fields)))
        for f in fields:
            print("    %s" % f)
    print("\nmatched: %d" % shown)


if __name__ == "__main__":
    main()
