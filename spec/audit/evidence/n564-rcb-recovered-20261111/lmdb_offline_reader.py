#!/usr/bin/env python3
"""Bounded read-only LMDB 64-bit little-endian page decoder.

For immutable forensic copies only. Does not import LMDB, create files, acquire
locks, or open a live environment. Rejects unsupported duplicate/LEAF2 layouts.
Entry counts are checked against each database's metadata before a census.
"""
import struct


class OfflineLMDB:
    def __init__(self, raw):
        self.raw = raw
        self.page_size = 4096
        metas = []
        for offset in (0, self.page_size):
            if struct.unpack_from("<II", raw, offset + 16) == (0xBEEFC0DE, 1):
                txn = struct.unpack_from("<Q", raw, offset + 144)[0]
                metas.append((txn, offset))
        if not metas:
            raise ValueError("no supported LMDB metadata page")
        self.txn, offset = max(metas)
        self.main = self.db_meta(raw[offset + 88:offset + 136])
        self.last_page = struct.unpack_from("<Q", raw, offset + 136)[0]
        if (self.last_page + 1) * self.page_size > len(raw):
            raise ValueError("truncated LMDB copy")

    @staticmethod
    def db_meta(raw):
        pad, flags, depth, branch, leaf, overflow, entries, root = struct.unpack("<IHHQQQQQ", raw)
        return dict(flags=flags, depth=depth, branch=branch, leaf=leaf,
                    overflow=overflow, entries=entries, root=root)

    def entries(self, db):
        if db["flags"] & (0x04 | 0x08 | 0x10):
            raise ValueError("unsupported DUPSORT/INTEGERKEY/DUPFIXED database")
        if db["entries"] == 0:
            return []
        seen = set()

        def walk(pgno, depth):
            if pgno in seen or pgno > self.last_page:
                raise ValueError("cyclic or out-of-bounds page")
            seen.add(pgno)
            start = pgno * self.page_size
            actual, pad, flags, lower, upper = struct.unpack_from("<QHHHH", self.raw, start)
            if actual != pgno or lower < 16 or lower > upper or upper > self.page_size:
                raise ValueError("invalid page header")
            if flags not in (1, 2):
                raise ValueError("unsupported page flags")
            if (flags == 2) != (depth == 1):
                raise ValueError("page depth mismatch")
            result = []
            for at in range(start + 16, start + lower, 2):
                relative = struct.unpack_from("<H", self.raw, at)[0]
                if relative < upper or relative + 8 > self.page_size:
                    raise ValueError("invalid node offset")
                node = start + relative
                lo, hi, node_flags, key_size = struct.unpack_from("<HHHH", self.raw, node)
                key = self.raw[node + 8:node + 8 + key_size]
                if flags == 1:
                    result.extend(walk(lo | (hi << 16) | (node_flags << 32), depth - 1))
                    continue
                size = lo | (hi << 16)
                value_at = node + 8 + key_size
                if node_flags & ~3:
                    raise ValueError("unsupported duplicate leaf value")
                if node_flags & 1:
                    overflow_page = struct.unpack_from("<Q", self.raw, value_at)[0]
                    overflow_at = overflow_page * self.page_size
                    if struct.unpack_from("<H", self.raw, overflow_at + 10)[0] != 4:
                        raise ValueError("invalid overflow page")
                    value_at = overflow_at + 16
                elif value_at + size > start + self.page_size:
                    raise ValueError("leaf value overflows its page")
                value = self.raw[value_at:value_at + size]
                if len(value) != size:
                    raise ValueError("truncated leaf value")
                result.append((key, value, node_flags))
            return result

        result = walk(db["root"], db["depth"])
        if len(result) != db["entries"]:
            raise ValueError("database entry count mismatch")
        return result

    def databases(self):
        out = {}
        for key, value, flags in self.entries(self.main):
            if flags != 2 or len(value) != 48:
                raise ValueError("main DB contains a non-database record")
            out[key] = self.db_meta(value)
        return out
