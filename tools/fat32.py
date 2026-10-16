"""FAT32 inside a GPT disk image, for testing Axiom's NVMe and FAT32 code.

Builds images (mkdisk.py) and checks them afterwards (fatcheck.py): every
chain, every long name, both FATs, lost and shared clusters.
"""
import struct
import uuid
import zlib

SECTOR = 512

ESP_TYPE = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
BASIC_TYPE = uuid.UUID("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7")

EOC = 0x0FFFFFFF


# --------------------------------------------------------------------------
#  GPT
# --------------------------------------------------------------------------
def write_gpt(img, total, parts):
    """parts: list of (type uuid, first lba, last lba, name)"""
    mbr = bytearray(SECTOR)
    mbr[446:462] = struct.pack("<BBBBBBBBII", 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF,
                               1, min(total - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    img[0:SECTOR] = mbr
    entries = bytearray(128 * 128)
    for i, (ptype, first, last, name) in enumerate(parts):
        e = ptype.bytes_le + uuid.uuid4().bytes_le + struct.pack("<QQQ", first, last, 0)
        e += name.encode("utf-16-le").ljust(72, b"\0")
        entries[i * 128:(i + 1) * 128] = e
    ecrc = zlib.crc32(entries)

    def header(cur, backup, entry_lba):
        h = bytearray(92)
        struct.pack_into("<8sIIIIQQQQ16sQIII", h, 0, b"EFI PART", 0x10000, 92, 0, 0,
                         cur, backup, 34, total - 34, uuid.uuid4().bytes_le,
                         entry_lba, 128, 128, ecrc)
        struct.pack_into("<I", h, 16, zlib.crc32(h))
        return bytes(h).ljust(SECTOR, b"\0")

    img[SECTOR:2 * SECTOR] = header(1, total - 1, 2)
    img[2 * SECTOR:34 * SECTOR] = entries
    img[(total - 33) * SECTOR:(total - 1) * SECTOR] = entries
    img[(total - 1) * SECTOR:total * SECTOR] = header(total - 1, 1, total - 33)


def read_gpt(img):
    hdr = img[SECTOR:2 * SECTOR]
    assert hdr[:8] == b"EFI PART", "no GPT"
    lba, count, size = struct.unpack_from("<QII", hdr, 72)
    parts = []
    for i in range(count):
        e = img[lba * SECTOR + i * size:lba * SECTOR + (i + 1) * size]
        if e[:16] == bytes(16):
            continue
        first, last = struct.unpack_from("<QQ", e, 32)
        name = e[56:128].decode("utf-16-le").rstrip("\0")
        parts.append((uuid.UUID(bytes_le=bytes(e[:16])), first, last, name))
    return parts


# --------------------------------------------------------------------------
#  FAT32
# --------------------------------------------------------------------------
def lfn_checksum(short):
    s = 0
    for b in short:
        s = (((s & 1) << 7) | (s >> 1)) + b & 0xFF
    return s


def short_83(name):
    """An 8.3 name and its NT case flags if `name` is one, else None."""
    if name.count(".") > 1 or name.startswith("."):
        return None
    base, _, ext = name.partition(".")
    if not 1 <= len(base) <= 8 or len(ext) > 3 or (name.endswith(".")):
        return None
    ok = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'()-@^_`{}~")
    flags = 0
    for part, bit in ((base, 0x08), (ext, 0x10)):
        if any(c.upper() not in ok for c in part):
            return None
        letters = [c for c in part if c.isalpha()]
        if letters and all(c.islower() for c in letters):
            flags |= bit
        elif any(c.islower() for c in letters):
            return None
    return (base.upper().ljust(8) + ext.upper().ljust(3)).encode(), flags


class Fat32:
    def __init__(self, img, first_lba, sectors):
        self.img = img
        self.base = first_lba * SECTOR
        self.sectors = sectors

    # -- formatting -------------------------------------------------------
    def format(self, spc=1, label=b"AXIOM TEST ", serial=0x41584F4D):
        self.spc, self.reserved, self.nfats = spc, 32, 2
        fatsz = 1
        while True:
            clusters = (self.sectors - self.reserved - self.nfats * fatsz) // spc
            need = ((clusters + 2) * 4 + SECTOR - 1) // SECTOR
            if need <= fatsz:
                break
            fatsz = need
        self.fatsz = fatsz
        self.data = self.reserved + self.nfats * fatsz
        self.maxcl = (self.sectors - self.data) // spc + 1
        bs = bytearray(SECTOR)
        bs[0:3] = b"\xEB\x58\x90"
        bs[3:11] = b"MSWIN4.1"
        struct.pack_into("<HBHBHHBHHHII", bs, 11, SECTOR, spc, self.reserved, self.nfats,
                         0, 0, 0xF8, 0, 63, 255, 0, self.sectors)
        struct.pack_into("<IHHIHH", bs, 36, fatsz, 0, 0, 2, 1, 6)
        bs[64] = 0x80
        bs[66] = 0x29
        struct.pack_into("<I", bs, 67, serial)
        bs[71:82] = label
        bs[82:90] = b"FAT32   "
        bs[510:512] = b"\x55\xaa"
        fsinfo = bytearray(SECTOR)
        struct.pack_into("<I", fsinfo, 0, 0x41615252)
        struct.pack_into("<III", fsinfo, 484, 0x61417272, 0xFFFFFFFF, 3)
        struct.pack_into("<I", fsinfo, 508, 0xAA550000)
        self.wsec(0, bs)
        self.wsec(1, fsinfo)
        self.wsec(6, bs)
        self.wsec(7, fsinfo)
        self.fat = [0] * (self.maxcl + 1)
        self.fat[0] = 0x0FFFFFF8
        self.fat[1] = EOC
        self.fat[2] = EOC                   # the root
        self.root = 2
        self.zero_cluster(2)
        self.next = 3

    def wsec(self, n, data):
        o = self.base + n * SECTOR
        self.img[o:o + len(data)] = data

    def cbytes(self):
        return self.spc * SECTOR

    def coff(self, c):
        return self.base + (self.data + (c - 2) * self.spc) * SECTOR

    def zero_cluster(self, c):
        o = self.coff(c)
        self.img[o:o + self.cbytes()] = bytes(self.cbytes())

    def alloc(self, n):
        chain = []
        for _ in range(n):
            c = self.next
            self.next += 1
            if chain:
                self.fat[chain[-1]] = c
            self.fat[c] = EOC
            chain.append(c)
        return chain

    def flush_fat(self):
        raw = struct.pack(f"<{len(self.fat)}I", *self.fat)
        raw = raw.ljust(self.fatsz * SECTOR, b"\0")
        for k in range(self.nfats):
            self.wsec(self.reserved + k * self.fatsz, raw)

    # -- building -----------------------------------------------------------
    def entries_for(self, name, attr, cluster, size, existing_shorts):
        sn = short_83(name)
        out = []
        if sn:
            short, flags = sn
        else:
            flags = 0
            base, dot, ext = name.rpartition(".")
            if not dot or not base:
                base, ext = name, ""
            clean = lambda s: "".join(c if c.upper() in
                                      "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'()-@^_`{}~"
                                      else "_" for c in s.replace(" ", "").replace(".", "")).upper()
            b, e = clean(base)[:6] or "_", clean(ext)[:3]
            n = 1
            while True:
                tail = "~" + str(n)
                short = ((b[:8 - len(tail)] + tail).ljust(8) + e.ljust(3)).encode()
                if short not in existing_shorts:
                    break
                n += 1
            sum_ = lfn_checksum(short)
            u = name.encode("utf-16-le")
            chars = [u[i:i + 2] for i in range(0, len(u), 2)]
            if len(chars) % 13:
                chars.append(b"\0\0")
            while len(chars) % 13:
                chars.append(b"\xff\xff")
            pieces = len(chars) // 13
            for k in range(pieces, 0, -1):
                c = chars[(k - 1) * 13:k * 13]
                e_ = bytearray(32)
                e_[0] = k | (0x40 if k == pieces else 0)
                e_[1:11] = b"".join(c[0:5])
                e_[11] = 0x0F
                e_[13] = sum_
                e_[14:26] = b"".join(c[5:11])
                e_[28:32] = b"".join(c[11:13])
                out.append(bytes(e_))
        existing_shorts.add(short)
        e_ = bytearray(32)
        e_[0:11] = short
        e_[11] = attr
        e_[12] = flags
        struct.pack_into("<HHHHHHHI", e_, 14, 0x6000, 0x5B50, 0x5B50,
                         cluster >> 16, 0x6000, 0x5B50, cluster & 0xFFFF, size)
        out.append(bytes(e_))
        return out

    def write_dir(self, cluster, parent, items):
        """items: list of (name, attr, first cluster, size)"""
        raw = []
        shorts = set()
        if parent is not None:
            for nm, c in ((b".          ", cluster), (b"..         ", parent)):
                e_ = bytearray(32)
                e_[0:11] = nm
                e_[11] = 0x10
                struct.pack_into("<HH", e_, 20, c >> 16, 0)
                struct.pack_into("<H", e_, 26, c & 0xFFFF)
                raw.append(bytes(e_))
        for name, attr, c, size in items:
            raw += self.entries_for(name, attr, c, size, shorts)
        data = b"".join(raw)
        per = self.cbytes()
        need = max(1, (len(data) + per - 1) // per)
        chain = [cluster]
        while len(chain) < need:
            c = self.next
            self.next += 1
            self.fat[chain[-1]] = c
            self.fat[c] = EOC
            chain.append(c)
        data = data.ljust(need * per, b"\0")
        for i, c in enumerate(chain):
            o = self.coff(c)
            self.img[o:o + per] = data[i * per:(i + 1) * per]

    def add_tree(self, tree, cluster=None, parent=None):
        """tree: {name: bytes | dict}. Returns the directory's cluster."""
        if cluster is None:
            cluster = self.root
        items = []
        for name, content in tree.items():
            if isinstance(content, dict):
                (c,) = self.alloc(1)
                self.zero_cluster(c)
                self.add_tree(content, c, 0 if cluster == self.root else cluster)
                items.append((name, 0x10, c, 0))
            else:
                n = (len(content) + self.cbytes() - 1) // self.cbytes()
                chain = self.alloc(n)
                for i, c in enumerate(chain):
                    o = self.coff(c)
                    piece = content[i * self.cbytes():(i + 1) * self.cbytes()]
                    self.img[o:o + self.cbytes()] = piece.ljust(self.cbytes(), b"\0")
                items.append((name, 0x20, chain[0] if chain else 0, len(content)))
        self.write_dir(cluster, parent, items)
        return cluster

    # -- reading ------------------------------------------------------------
    def mount(self):
        bs = self.img[self.base:self.base + SECTOR]
        (bps, self.spc, self.reserved, self.nfats) = struct.unpack_from("<HBHB", bs, 11)
        assert bps == SECTOR
        self.fatsz, = struct.unpack_from("<I", bs, 36)
        self.root, = struct.unpack_from("<I", bs, 44)
        total, = struct.unpack_from("<I", bs, 32)
        self.data = self.reserved + self.nfats * self.fatsz
        self.maxcl = (total - self.data) // self.spc + 1
        fats = []
        for k in range(self.nfats):
            o = self.base + (self.reserved + k * self.fatsz) * SECTOR
            fats.append(bytes(self.img[o:o + (self.maxcl + 1) * 4]))
        self.fat_copies_match = all(f == fats[0] for f in fats)
        self.fat = [v & 0x0FFFFFFF for v in struct.unpack(f"<{self.maxcl + 1}I", fats[0])]
        o = self.base + SECTOR
        self.fsinfo_next, = struct.unpack_from("<I", self.img, o + 492)
        return self

    def chain(self, c):
        out = []
        while 2 <= c <= self.maxcl:
            if c in out:
                raise ValueError(f"loop in chain at {c}")
            out.append(c)
            c = self.fat[c]
        if out and c < 0x0FFFFFF8:
            raise ValueError(f"chain ends in {c:#x}, not end-of-chain")
        return out

    def read_chain(self, c, size=None):
        data = b"".join(bytes(self.img[self.coff(x):self.coff(x) + self.cbytes()])
                        for x in self.chain(c))
        return data if size is None else data[:size]

    def listdir(self, c):
        """-> list of dict(name, short, attr, cluster, size, problems)"""
        raw = self.read_chain(c)
        out, lfn, problems = [], {}, []
        expect = None
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                lfn, expect = {}, None
                continue
            if e[11] & 0x3F == 0x0F:
                seq = e[0] & 0x1F
                if e[0] & 0x40:
                    lfn = {"sum": e[13], "parts": {}}
                    expect = seq
                elif expect is None or seq != expect - 1 or e[13] != lfn.get("sum"):
                    problems.append(f"orphan long-name piece at entry {i // 32}")
                    lfn, expect = {}, None
                    continue
                expect = seq
                chars = e[1:11] + e[14:26] + e[28:32]
                lfn["parts"][seq] = chars
                continue
            if e[11] & 0x08:
                continue
            short = bytes(e[0:11])
            name = None
            if lfn and expect == 1:
                if lfn["sum"] != lfn_checksum(short):
                    problems.append(f"long name checksum wrong before {short!r}")
                else:
                    u = b"".join(lfn["parts"][k] for k in sorted(lfn["parts"]))
                    name = u.decode("utf-16-le", "replace").split("\0")[0]
            elif lfn:
                problems.append(f"incomplete long name before {short!r}")
            lfn, expect = {}, None
            base = short[:8].decode("latin-1").rstrip()
            ext = short[8:].decode("latin-1").rstrip()
            if e[12] & 0x08:
                base = base.lower()
            if e[12] & 0x10:
                ext = ext.lower()
            sname = base + ("." + ext if ext else "")
            hi, lo = struct.unpack_from("<H", e, 20)[0], struct.unpack_from("<H", e, 26)[0]
            size, = struct.unpack_from("<I", e, 28)
            out.append(dict(name=name or sname, short=sname, raw=short, attr=e[11],
                            cluster=hi << 16 | lo, size=size))
        return out, problems


def check(fs, verbose=True):
    """Walk everything. -> (tree dict path -> bytes|None for dirs, problems)"""
    problems = []
    if not fs.fat_copies_match:
        problems.append("the FAT copies differ")
    owner = {}
    files = {}

    def claim(chain, path):
        for c in chain:
            if c in owner:
                problems.append(f"cluster {c} in both {owner[c]} and {path}")
            owner[c] = path

    def walk(c, path, parent):
        try:
            chain = fs.chain(c)
        except ValueError as e:
            problems.append(f"{path or '/'}: {e}")
            return
        claim(chain, path or "/")
        entries, probs = fs.listdir(c)
        problems.extend(f"{path or '/'}: {p}" for p in probs)
        shorts = set()
        names = set()
        for e in entries:
            if e["raw"] in shorts:
                problems.append(f"{path}/: two entries are {e['raw']!r}")
            shorts.add(e["raw"])
            if e["name"] in (".", ".."):
                want = c if e["name"] == "." else (0 if parent in (None, fs.root) else parent)
                if e["cluster"] != want:
                    problems.append(f"{path}/{e['name']} points at {e['cluster']}, not {want}")
                continue
            if e["name"].lower() in names:
                problems.append(f"{path}/: two entries are named {e['name']!r}")
            names.add(e["name"].lower())
            p = f"{path}/{e['name']}"
            if e["attr"] & 0x10:
                files[p] = None
                walk(e["cluster"], p, c)
            else:
                try:
                    chain = fs.chain(e["cluster"]) if e["cluster"] else []
                except ValueError as ex:
                    problems.append(f"{p}: {ex}")
                    continue
                need = (e["size"] + fs.cbytes() - 1) // fs.cbytes()
                if len(chain) != need:
                    problems.append(f"{p}: {len(chain)} clusters for {e['size']} bytes")
                claim(chain, p)
                files[p] = fs.read_chain(e["cluster"], e["size"]) if chain else b""

    walk(fs.root, "", None)
    used = {c for c in range(2, fs.maxcl + 1) if fs.fat[c]}
    lost = used - set(owner)
    if lost:
        problems.append(f"{len(lost)} clusters marked used but in no file: {sorted(lost)[:10]}")
    return files, problems
