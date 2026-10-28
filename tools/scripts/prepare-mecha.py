#!/usr/bin/env python3
"""Normalize pinned Mecha reflection in a generated Zig 0.17 build copy."""
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
for old,new,count in [
 ('meta.Tuple(&types)','@Tuple(&types)',1),
 ('const struct_fields = @typeInfo(T).@"struct".fields;','const struct_fields = @typeInfo(T).@"struct".field_names;',1),
 ('info.is_tuple and info.fields.len == struct_fields.len','info.is_tuple and info.field_names.len == struct_fields.len',1),
 ('@field(res, field.name) = value[i];','@field(res, field) = value[i];',1),
 ('@field(res, struct_fields[0].name) = value;','@field(res, struct_fields[0]) = value;',1),
 ('@typeInfo(Enum).@"enum".fields','@typeInfo(Enum).@"enum".field_names',1),
 ('field.name','field',4),
]:
 if text.count(old)!=count:raise SystemExit('Mecha source changed; review the documented Zig 0.17 adapter')
 text=text.replace(old,new)
Path(sys.argv[2]).write_text(text)
