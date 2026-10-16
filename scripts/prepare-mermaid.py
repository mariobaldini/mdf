#!/usr/bin/env python3
"""Apply MDF's narrow font integration to the pinned native Mermaid source."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = root / 'zig-pkg/mermaid-renderer'
manifest = source / 'Cargo.toml'
text = manifest.read_text()
original = 'fontdb = "0.23"'
modified = 'fontdb = { version = "0.23", default-features = false }'
if modified not in text:
    if text.count(original) != 1:
        raise SystemExit('Unsupported Mermaid font dependency declaration')
    manifest.write_text(text.replace(original, modified, 1))
adapter = (root / 'frontend/mermaid/text_metrics.rs').read_bytes()
target = source / 'src/text_metrics.rs'
if target.read_bytes() != adapter:
    target.write_bytes(adapter)
# Expose only the adapter's scoped font handoff to the FFI wrapper. No system
# discovery feature is enabled in the upstream dependency.
library = source / 'src/lib.rs'
text = library.read_text()
if '\npub mod text_metrics;' not in text:
    if text.count('\nmod text_metrics;') != 1:
        raise SystemExit('Unsupported Mermaid text measurement module')
    library.write_text(text.replace('\nmod text_metrics;', '\npub mod text_metrics;', 1))
