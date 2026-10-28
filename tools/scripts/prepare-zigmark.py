#!/usr/bin/env python3
"""Checked generated copies for Zig 0.17 and MDF's Markdown dialect."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import sys

source,destination=map(Path,sys.argv[1:3])
shutil.copytree(source,destination,dirs_exist_ok=True)
changes={
 'markdown/inline.zig':[
  ('var t = [_]bool{false} ** 256;','var t: [256]bool = @splat(false);',2),
  ('var bs = [_]u8{0} ** 8192;','var bs: [8192]u8 = @splat(0);',1)],
 'markdown/parser.zig':[
  ('fn skipFrontmatter(lines: []const []const u8) usize {','fn skipFrontmatter(lines: []const []const u8) usize {\n    if (@import("mdf_options").standard_frontmatter) return 0;',1),
  ('fn isHtmlBlockStart(t: []const u8) bool {','fn isHtmlBlockStart(t: []const u8) bool {\n    if (@import("mdf_options").disable_html_blocks) return false;',1)],
 'markdown/renderers/html.zig':[
  ('var table = [_]bool{false} ** 128;','var table: [128]bool = @splat(false);',2)],
 'markdown/security_test.zig':[
  ('"a" ** 128',"&@as([128]u8, @splat('a'))",1)],
}
for name,replacements in changes.items():
 p=destination/name;text=p.read_text()
 for old,new,count in replacements:
  if text.count(old)!=count:raise SystemExit(f'Zigmark {name} changed; review the documented adapter')
  text=text.replace(old,new)
 p.write_text(text)
# Use the complete standard entity data in the HTML reference renderer too.
p=destination/'markdown/renderers/html.zig';text=p.read_text()
start=text.index('fn tryDecodeEntity(s: []const u8, i: usize) ?DecodedEntity {')
end=text.index('\n}',start)+2
if hashlib.sha256(text[start:end].encode()).hexdigest() != 'c86e08064da930b9f74d6af262cc41737eb33a0c43aeefd2a48dd0cbaea1bd1c':
 raise SystemExit('Zigmark entity decoder changed; review the documented adapter')
text=text[:start]+'''fn tryDecodeEntity(s: []const u8, i: usize) ?DecodedEntity {
    const decoded = @import("html_entities").decode(s, i) orelse return null;
    return .{ .bytes = decoded.bytes, .len = decoded.len, .consumed = decoded.consumed };
}'''+text[end:]
p.write_text(text)
(destination/'mdf.zig').write_text('pub const Parser = @import("markdown/parser.zig");\npub const AST = @import("markdown/ast.zig");\npub const Inline = @import("markdown/inline.zig");\npub const HTML = @import("markdown/renderers/html.zig");\n')
for patch in sys.argv[3:]:
 subprocess.run(['patch','--batch','--fuzz=0','-p1','-i',str(Path(patch).resolve())],cwd=destination,check=True,stdout=subprocess.DEVNULL)
