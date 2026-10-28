#!/usr/bin/env python3
"""Normalize obsolete array repetition in a generated copy of pinned mvzr."""
from pathlib import Path
import sys

text=Path(sys.argv[1]).read_text()
for old,new,count in [
    ('[1]RegOp{.{ .unused = {} }} ** ops','@splat(.{ .unused = {} })',1),
    ('[1]CharSet{.{ .low = 0, .hi = 0 }} ** char_sets','@splat(.{ .low = 0, .hi = 0 })',1),
    ('"a" ** 2048',"&@as([2048]u8, @splat('a'))",2),
    ('"12345," ** 255','std.mem.asBytes(&@as([255][6]u8, @splat("12345,".*)))',1),
]:
    if text.count(old)!=count:
        raise SystemExit('mvzr source changed; review the documented Zig 0.17 adapter')
    text=text.replace(old,new)
Path(sys.argv[2]).write_text(text)
