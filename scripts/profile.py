#!/usr/bin/env python3
"""Profile all three Markdown samples and write one offline HTML startup report."""

import argparse
from collections import defaultdict
import ctypes
from datetime import datetime, timezone
import hashlib
import heapq
import json
import math
import mmap
import os
from pathlib import Path
import platform
import random
import re
import shutil
import statistics
import struct
import subprocess
import sys
import tempfile
import time
import zlib


TRACKS = {"launch": "Pre-load / startup", "gui": "GUI / main thread", "document": "Document worker", "fonts": "Deferred monospace worker",
          "navigation": "Navigation / assets worker", "images": "Images / diagrams worker", "fallback": "Sans glyph fallback worker",
          "input": "Keyboard preparation worker"}


def command_output(arguments, cwd=None):
    try:
        result = subprocess.run(arguments, cwd=cwd, capture_output=True, text=True, timeout=10,
                                env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def file_info(path, label=None):
    if not path.is_file():
        return {"path": label or str(path), "available": False}
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"path": label or str(path), "available": True,
            "bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def dependencies(manifest):
    """Read the pinned URL/hash records from the project's flat ZON manifests."""
    section = manifest.split(".dependencies = .{", 1)[-1]
    records = {}
    for name, body in re.findall(r"\.([A-Za-z0-9_]+)\s*=\s*\.\{(.*?)\n\s*\},", section, re.S):
        record = dict(re.findall(r'\.(url|hash|version)\s*=\s*"([^"]+)"', body))
        if "hash" in record:
            records[name] = record
    return records


def font_metadata(path):
    """Read family, style, and version from the OpenType name table."""
    data = path.read_bytes()
    result = {}
    try:
        count = struct.unpack_from(">H", data, 4)[0]
        for index in range(count):
            tag, _, offset, _ = struct.unpack_from(">4sIII", data, 12 + 16 * index)
            if tag != b"name":
                continue
            _, names, strings = struct.unpack_from(">HHH", data, offset)
            for name_index in range(names):
                platform_id, _, language, name_id, length, position = struct.unpack_from(">HHHHHH", data, offset + 6 + 12 * name_index)
                if name_id not in (1, 2, 5) or (platform_id == 3 and language not in (0, 0x409)):
                    continue
                key = {1: "family", 2: "style", 5: "version"}[name_id]
                raw = data[offset + strings + position:offset + strings + position + length]
                result[key] = raw.decode("utf-16-be" if platform_id in (0, 3) else "mac_roman", errors="replace")
            break
    except (struct.error, ValueError):
        result["version"] = "unavailable"
    return result


def elf_file(path):
    """Read the file-backed sections of our ELF64 little-endian Linux target."""
    data = path.read_bytes()
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("Size analysis requires a little-endian ELF64 executable.")
    offset = struct.unpack_from("<Q", data, 40)[0]
    stride, count, names_index = struct.unpack_from("<HHH", data, 58)
    if stride < 64 or not count or names_index >= count or offset + stride * count > len(data):
        raise ValueError("Invalid ELF section table.")
    sections = []
    for index in range(count):
        values = struct.unpack_from("<IIQQQQIIQQ", data, offset + index * stride)
        section = dict(zip(("name_offset", "type", "flags", "address", "offset", "bytes", "link", "info", "align", "stride"), values))
        if section["type"] != 8 and section["offset"] + section["bytes"] > len(data):
            raise ValueError("ELF section extends beyond the file.")
        sections.append(section)
    names = sections[names_index]
    strings = data[names["offset"]:names["offset"] + names["bytes"]]
    for section in sections:
        section["name"] = strings[section["name_offset"]:].split(b"\0", 1)[0].decode("utf-8", errors="replace")
    note = next((s for s in sections if s["name"] == ".note.gnu.build-id" and s["type"] != 8), None)
    return {"data": data, "sections": sections,
            "build_id": data[note["offset"]:note["offset"] + note["bytes"]].hex() if note else None}


def symbol_family(name):
    """Attribute surviving symbols; LTO inlined bytes stay with their caller."""
    if name == "main":
        return ("Application", "Main entry point")
    if "bundled_font" in name or name == "mdf_font_resource":
        return ("Application", "Font setup")
    if "diagram_renderer" in name or "svg_image" in name or "6Module7prepare" in name:
        return ("Application", "Diagram module loading")
    if "nlohmann" in name:
        return ("Bundled libraries", "nlohmann JSON")
    if "mermaid_rs_renderer" in name or "mdf_mermaid" in name or name == "mdf_render_mermaid":
        return ("Bundled libraries", "Mermaid renderer")
    if any(crate in name for crate in ("resvg", "usvg", "tiny_skia", "rustybuzz", "fontdb", "ttf_parser", "svgtypes", "simplecss")):
        return ("Bundled libraries", "SVG rendering")
    if name.startswith(("_R", "__rust", "__rg_", "__rdl_", "rust_eh_", "rust_begin_")) or re.search(r"17h[0-9a-f]{16}E(?:\..*)?$", name):
        return ("Language runtimes", "Rust standard library & diagram support")
    for prefix, label in (("png_", "PNG"), ("fltk_png_", "PNG"), ("fltk_z_", "ZLIB"),
                          ("jpeg_", "JPEG"), ("jinit_", "JPEG"),
                          ("jcopy_", "JPEG"), ("jzero_", "JPEG"), ("jdiv_", "JPEG"),
                          ("jround_", "JPEG"), ("libdecor", "libdecor"), ("md_", "MD4C")):
        if name.startswith(prefix):
            return ("Bundled libraries", label)
    if name.startswith(("inflate", "deflate", "adler32", "crc32", "zlib", "z_", "_tr_",
                        "gz", "compress", "uncompress", "get_crc_table")):
        return ("Bundled libraries", "ZLIB")
    for family, label in (("DocumentView", "Document rendering"), ("Minimap", "Minimap"),
                          ("FontStore", "Font setup"), ("App", "Window & controls"),
                          ("CodeFont", "System font rendering"), ("MonospaceWorker", "Deferred font loading"),
                          ("FallbackWorker", "Deferred font loading"),
                          ("MainWindow", "Window & controls"), ("IconButton", "Window & controls"),
                          ("ContentsBrowser", "Table of contents"), ("MenuAction", "Window & controls"),
                          ("ImageWorker", "Image & diagram preparation"),
                          ("Settings", "Settings"), ("KeyboardPreparation", "Native startup")):
        if re.search(rf"(?:\d|^){family}(?:\d|[A-Z_]|$)", name):
            return ("Application", label)
    if any(helper in name for helper in ("read_block", "read_spans", "take_json")):
        return ("Application", "Core interface")
    if name.startswith("fl_mdf_"):
        return ("Application", "Native startup")
    if "Fl_" in name or name.startswith(("fl_", "_ZN2Fl", "_ZNK2Fl", "_ZZN2Fl")):
        return ("Bundled libraries", "FLTK")
    if name.startswith(("core.", "loader.", "navigation.", "layout.", "document.", "footnotes.",
                        "settings.", "profiling.", "runtime.", "mdf_")):
        return ("Application", "Zig " + name.split(".", 1)[0] if "." in name else "Core API")
    if name.startswith(("__wrap_select", "__wrap_poll", "__wrap_wl_display_")) or "profile_gui_wait_reason" in name:
        return ("Application", "Profiling")
    if name.startswith(("std.", "builtin.", "compiler_rt.", "debug.", "__zig")):
        return ("Language runtimes", "Zig standard library")
    if name.startswith(("_ZNSt", "_ZNKSt", "_ZSt", "_ZN9__gnu_cxx", "_ZNK9__gnu_cxx", "_Unwind_", "__cxa_", "__gxx_")) or "__cxxabiv1" in name:
        return ("Language runtimes", "C++ standard library & exceptions")
    if name.startswith(("__udiv", "__div", "__mod", "__umod", "__mul", "__float", "__fix", "__extend", "__trunc")):
        return ("Language runtimes", "Compiler support")
    return None


def binary_breakdown(root, binary):
    """Partition actual executable file bytes once, without archive-size estimates."""
    try:
        image = elf_file(binary)
    except (OSError, ValueError, struct.error) as error:
        return {"available": False, "reason": str(error)}
    symbols = image
    if not any(s["type"] == 2 for s in image["sections"]):
        symbols = None
        for candidate in (binary.with_name(binary.name + ".debug"), root / "build/fltk-ui/ReleaseFast/mdf.debug"):
            try:
                debug = elf_file(candidate)
            except (OSError, ValueError, struct.error):
                continue
            if image["build_id"] and debug["build_id"] == image["build_id"] and any(s["type"] == 2 for s in debug["sections"]):
                symbols = debug
                break
    spans = []

    def add(start, end, path, priority):
        start, end = max(0, start), min(len(image["data"]), end)
        if end > start:
            spans.append((start, end, path, priority))

    add(0, len(image["data"]), ("ELF format & loader", "Headers, section table & padding"), 0)
    for section in image["sections"]:
        if section["type"] in (0, 8):  # SHT_NOBITS consumes RAM, not disk bytes.
            continue
        name = section["name"]
        if name in (".mdf_mermaid", ".mdf_svg"):
            add(section["offset"], section["offset"] + section["bytes"],
                ("Compressed renderers", "Mermaid layout (zlib)" if name == ".mdf_mermaid" else "SVG rendering (zlib)"), 30)
            continue
        if name == ".mdf_diagram":
            add(section["offset"], section["offset"] + section["bytes"],
                ("Compressed diagram module", "Mermaid, SVG and Rust support (zlib)"), 30)
            continue
        if name in (".text", ".rodata", ".data", ".data.rel.ro", ".tdata"):
            group = "Unattributed code & alignment" if section["flags"] & 4 else "Shared data & constants"
        else:
            group = "ELF format & loader"
        add(section["offset"], section["offset"] + section["bytes"], (group, name), 10)
    if symbols:
        targets = {s["name"]: s for s in image["sections"] if s["flags"] & 2 and s["type"] != 8}
        for table in symbols["sections"]:
            if table["type"] != 2 or table["stride"] < 24 or table["link"] >= len(symbols["sections"]):
                continue
            strings = symbols["sections"][table["link"]]
            names = symbols["data"][strings["offset"]:strings["offset"] + strings["bytes"]]
            for offset in range(table["offset"], table["offset"] + table["bytes"], table["stride"]):
                name_offset, info, _, index, address, size = struct.unpack_from("<IBBHQQ", symbols["data"], offset)
                if not size or info & 15 not in (1, 2, 6) or index >= len(symbols["sections"]):
                    continue
                source = symbols["sections"][index]
                target = targets.get(source["name"])
                if not target or source["address"] != target["address"]:
                    continue
                name = names[name_offset:].split(b"\0", 1)[0].decode("utf-8", errors="replace")
                family = symbol_family(name)
                if family or info & 15 == 2:
                    start = target["offset"] + address - target["address"]
                    add(max(start, target["offset"]), min(start + size, target["offset"] + target["bytes"]),
                        family or ("Unattributed code & alignment", name), 20 if family else 15)
    for path in sorted((root / "assets/fonts/open-sans").glob("*.ttf")):
        font = path.read_bytes()
        start = image["data"].find(font) if font else -1
        compressed = False
        if start < 0 and "Italic" in path.stem:
            font = struct.pack("<8sII", b"MDFONT1\0", len(font), zlib.crc32(font)) + zlib.compress(font, 9)
            start = image["data"].find(font)
            compressed = True
        if start >= 0:
            face = path.stem.removeprefix("OpenSans-").replace("BoldItalic", "Bold italic")
            add(start, start + len(font), ("Fonts", "Open Sans " + face + (" (zlib)" if compressed else "")), 30)

    # A sweep resolves aliases, overlapping symbols, and embedded font objects.
    # Each physical byte belongs to exactly one rectangle.
    changes = defaultdict(list)
    for index, (start, end, _, priority) in enumerate(spans):
        changes[start].append((True, index))
        changes[end].append((False, index))
    active, heap, totals = set(), [], defaultdict(int)
    previous, owner = 0, None
    for position in sorted(changes):
        if owner is not None:
            totals[spans[owner][2]] += position - previous
        for entering, index in changes[position]:
            if entering:
                active.add(index)
                start, end, _, priority = spans[index]
                heapq.heappush(heap, (-priority, end - start, index))
            else:
                active.discard(index)
        while heap and heap[0][2] not in active:
            heapq.heappop(heap)
        owner = heap[0][2] if heap else None
        previous = position
    groups = defaultdict(list)
    for (group, name), size in sorted(totals.items()):
        if size:
            groups[group].append({"name": name, "bytes": size})
    other = sorted(groups.get("Unattributed code & alignment", []), key=lambda item: -item["bytes"])
    if other:
        # Keep the largest retained functions inspectable without embedding a
        # symbol dump in every standalone report.
        kept, remainder = other[:16], other[16:]
        mangled = [item["name"] for item in kept if item["name"].startswith("_Z")]
        demangled = command_output(["c++filt", "--", *mangled]) if mangled else None
        labels = dict(zip(mangled, demangled.splitlines())) if demangled else {}
        for item in kept:
            item["name"] = labels.get(item["name"], item["name"])[:140]
            if item["name"] == ".text":
                item["name"] = "Code alignment & unnamed regions"
        if remainder:
            kept.append({"name": "Other retained functions", "bytes": sum(item["bytes"] for item in remainder)})
        groups["Unattributed code & alignment"] = kept
    children = [{"name": name, "bytes": sum(c["bytes"] for c in items), "children": items}
                for name, items in groups.items()]
    children.sort(key=lambda item: (-item["bytes"], item["name"]))
    result = {"available": True, "symbols_available": symbols is not None,
              "name": binary.name, "bytes": len(image["data"]), "children": children}
    section = next((s for s in image["sections"] if s["name"] == ".mdf_diagram"), None)
    if section and section["bytes"] >= 40:
        magic, abi, header, packed, expanded, checksum, flags = struct.unpack_from("<8sIIQQII", image["data"], section["offset"])
        if magic == b"MDFDG01\0" and abi == 1 and header == 40 and packed == section["bytes"]-40 and not flags:
            result["diagram_module"] = {"packed_bytes": packed, "expanded_bytes": expanded,
                                        "header_bytes": header, "codec": "zlib", "abi": abi}
    modules = []
    for section in image["sections"]:
        if section["name"] not in (".mdf_mermaid", ".mdf_svg") or section["bytes"] < 40:
            continue
        magic, abi, header, packed, expanded, checksum, flags = struct.unpack_from("<8sIIQQII", image["data"], section["offset"])
        if magic == b"MDFDG01\0" and abi == 2 and header == 40 and packed == section["bytes"] - 40 and not flags:
            modules.append({"name": "Mermaid renderer" if section["name"] == ".mdf_mermaid" else "SVG rendering",
                            "packed_bytes": packed, "expanded_bytes": expanded, "header_bytes": header,
                            "codec": "zlib", "abi": abi})
    if modules:
        result["diagram_modules"] = modules
    return result


def project_context(root, binary, document, run):
    """Keep build identity and actual library sizes, without source snapshots."""
    frontend = json.loads((root / "frontend/dependencies.json").read_text())
    direct = dependencies((root / "build.zig.zon").read_text())
    libraries = []
    sdk = root / "build/fltk/ReleaseFast/lib"

    def bundled(name, version, role, paths=(), basis="static archive", included=None):
        files = [path for path in paths if path.is_file()]
        libraries.append({"name": name, "version": version, "role": role,
                          "linkage": "bundled", "bytes": sum(path.stat().st_size for path in files) if files else None,
                          "size_basis": basis if files else included or "included in executable"})

    bundled("FLTK", frontend["fltk"]["version"], "Native Wayland UI and image wrappers",
            [sdk / "libfltk.a", sdk / "libfltk_images.a"], "static archives")
    md4c = root / "zig-pkg" / direct["md4c"]["hash"] / "CMakeLists.txt"
    match = re.search(r"project\s*\([^)]*?VERSION\s+([0-9.]+)", md4c.read_text(), re.I) if md4c.is_file() else None
    bundled("MD4C", match.group(1) if match else "pinned commit", "Markdown parser")
    bundled("nlohmann JSON", frontend["nlohmann_json"]["version"], "Control messages",
            [root / "zig-pkg/nlohmann/json.hpp"], "header file")
    if "mermaid" in frontend and "rendered_diagrams" in run.get("metrics", {}):
        bundled("Mermaid renderer", frontend["mermaid"]["version"], "Native diagram parsing and layout")
        bundled("SVG rendering", "resvg/usvg 0.47.0", "Diagram rasterization and embedded-font shaping")
    for name, directory, filename, pattern, archive, role in (
        ("libpng", "png", "png.h", r'#define PNG_LIBPNG_VER_STRING\s+"([^"]+)"', "png", "PNG decoding"),
        ("IJG JPEG", "jpeg", "README", r"README for release (\S+)", "jpeg", "JPEG decoding"),
        ("zlib", "zlib", "zlib.h", r'#define ZLIB_VERSION\s+"([^"]+)"', "z", "Image decompression"),
        ("libdecor", "libdecor", "meson.build", r"version:\s*'([^']+)'", None, "Native title bar (48 logical pixels)"),
    ):
        source = root / "zig-pkg/fltk" / directory / filename
        match = re.search(pattern, source.read_text()) if source.is_file() else None
        bundled(name, match.group(1) if match else "bundled with FLTK", role,
                [sdk / f"libfltk_{archive}.a"] if archive else (), included="included in FLTK")
    faces = sorted((root / "assets/fonts/open-sans").glob("*.ttf"))
    bundled("Open Sans", font_metadata(faces[0]).get("version", "bundled") if faces else "unavailable",
            "Regular/bold and independently compressed italic Latin subset faces", faces, "font data")
    if run.get("metrics", {}).get("monospace_status") == "ready":
        info = run["metrics"]
        libraries.append({"name": info.get("monospace_family", "System monospace"), "version": "system font",
                          "role": "Code font loaded after the first Markdown frame", "linkage": "runtime font",
                          "bytes": info.get("monospace_bytes"), "size_basis": "selected system font files; outside executable"})
    if run.get("metrics", {}).get("fallback_status") == "ready":
        info = run["metrics"]
        libraries.append({"name": info.get("fallback_families", "System Sans fallback"), "version": "system fonts",
                          "role": "Missing document glyphs; loaded after the first viewport", "linkage": "runtime font",
                          "bytes": info.get("fallback_bytes"), "size_basis": "selected system font files; outside executable"})

    # Resolve actual runtime files rather than reporting source-tree sizes.
    linked = {}
    for line in (command_output(["ldd", str(binary)]) or "").splitlines():
        match = re.match(r"\s*(\S+) => (/\S+)", line)
        if match:
            linked[match.group(1)] = Path(match.group(2)).resolve()
    primary = (
        ("pangocairo", "libpangocairo-1.0.so.", "Pango / Cairo text"),
        ("pangoft2", "libpangoft2-1.0.so.", "Pango font backend"),
        ("pango", "libpango-1.0.so.", "Text layout"),
        ("cairo", "libcairo.so.", "Drawing"),
        ("fontconfig", "libfontconfig.so.", "Private font configuration"),
        ("freetype2", "libfreetype.so.", "Font rasterization"),
        ("harfbuzz", "libharfbuzz.so.", "Text shaping"),
        ("wayland-client", "libwayland-client.so.", "Wayland connection"),
        ("wayland-cursor", "libwayland-cursor.so.", "Wayland cursors"),
        ("xkbcommon", "libxkbcommon.so.", "Keyboard input"),
    )
    used = set()
    for package, prefix, role in primary:
        found = next(((name, path) for name, path in linked.items() if name.startswith(prefix)), None)
        path = found[1] if found else None
        if found:
            used.add(found[0])
        libraries.append({"name": package, "version": command_output(["pkg-config", "--modversion", package]),
                          "role": role, "linkage": "shared", "bytes": path.stat().st_size if path and path.is_file() else None,
                          "size_basis": "shared library"})
    indirect = [{"name": name, "bytes": path.stat().st_size} for name, path in sorted(linked.items())
                if name not in used and path.is_file()]
    binary_size = binary_breakdown(root, binary)
    groups = {group["name"]: group for group in binary_size.get("children", [])}
    if "diagram_module" in binary_size:
        for library in libraries:
            if library["name"] in ("Mermaid renderer", "SVG rendering"):
                library["size_basis"] = "inside the shared compressed payload"
        bundled("Compressed diagram module", "ABI 1", "Mermaid, SVG and Rust support; loaded after the first viewport")
    retained = {item["name"]: item["bytes"] for item in groups.get("Bundled libraries", {}).get("children", [])}
    aliases = {"libpng": "PNG", "IJG JPEG": "JPEG", "zlib": "ZLIB"}
    for library in libraries:
        library["linked_bytes"] = (groups.get("Compressed diagram module", {}).get("bytes") if library["name"] == "Compressed diagram module"
                                   else groups.get("Fonts", {}).get("bytes") if library["name"] == "Open Sans"
                                   else retained.get(aliases.get(library["name"], library["name"]))) if library["linkage"] == "bundled" else None
        module = next((item for item in binary_size.get("diagram_modules", []) if item["name"] == library["name"]), None)
        if module:
            library["linked_bytes"] = module["packed_bytes"] + module["header_bytes"]
            library["size_basis"] = "independent compressed module"
    return {"name": "Markdown FAST", "version": run["version"],
            "build": f'{run["mode"]} / {run.get("ui_mode", "Release")} · x86_64 baseline · LTO',
            "compiler": command_output([os.environ.get("ZIG", "zig"), "version"]),
            "binaries": [file_info(binary, binary.name)],
            "input": file_info(document, document.name), "libraries": libraries, "indirect_libraries": indirect,
            "binary_size": binary_size}


def memory_cache_info():
    values = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            name, value = line.split(":", 1)
            if name in ("Cached", "Buffers", "SReclaimable", "MemAvailable", "Dirty", "Writeback"):
                values[name] = int(value.split()[0])
    except OSError:
        pass
    return values


def drop_linux_caches(flush_paths=None):
    """Reset eligible filesystem caches, and fail rather than record a warm run."""
    if sys.platform != "linux":
        raise RuntimeError("Cold startup profiling requires Linux /proc/sys/vm/drop_caches.")
    before = memory_cache_info()
    started = time.monotonic_ns()
    if flush_paths is None:
        os.sync()
        sync_scope = "global sync"
    else:
        if not flush_paths:
            raise ValueError("File-specific cache reset requires benchmark inputs")
        # Dirty unrelated mounts can block sync() indefinitely. Flush every
        # benchmark file instead, then reclaim the same kernel caches. mincore
        # proves that executable and fixture pages were actually evicted.
        for path in dict.fromkeys(flush_paths):
            fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        sync_scope = "fsync executable, document and local images"
    if os.geteuid() == 0:
        Path("/proc/sys/vm/drop_caches").write_text("3\n")
    else:
        sudo = shutil.which("sudo")
        if sudo is None:
            raise RuntimeError("Cold profiling requires sudo. Run make setup.")
        command = [sudo, "-n", "/usr/bin/tee", "/proc/sys/vm/drop_caches"]
        reset = subprocess.run(command, input="3\n", capture_output=True, text=True)
        if reset.returncode and sys.stdin.isatty():
            auth = subprocess.run([sudo, "-v"])
            if auth.returncode == 0:
                reset = subprocess.run(command, input="3\n", capture_output=True, text=True)
        if reset.returncode:
            raise RuntimeError("Linux caches were not cleared; no launch was measured. "
                               "Run sudo -v in this terminal, then make profile. " + reset.stderr.strip())
    return {"success": True, "sync": flush_paths is None, "sync_scope": sync_scope, "drop_caches": 3,
            "duration_ms": (time.monotonic_ns() - started) / 1_000_000,
            "before_kib": before, "after_kib": memory_cache_info(),
            "xdg_cache": "empty directory unique to this launch",
            "shader_cache_environment": {"MESA_SHADER_CACHE_DISABLE": "true", "__GL_SHADER_DISK_CACHE": "0"}}


def binary_cache_state(binary):
    """Use mincore on a PROT_NONE mapping; never read or fault executable pages."""
    fd = os.open(binary, os.O_RDONLY | os.O_CLOEXEC)
    try:
        stat = os.fstat(fd)
        if stat.st_size <= 0:
            raise RuntimeError("Cannot verify cache residency for an empty executable.")
        if stat.st_uid != os.geteuid() and os.geteuid() != 0 and not os.access(binary, os.W_OK):
            raise RuntimeError("Cache residency verification requires an executable owned by this user. Run make profile.")
        page_size = os.sysconf("SC_PAGE_SIZE")
        pages = (stat.st_size + page_size - 1) // page_size
        libc = ctypes.CDLL(None, use_errno=True)
        libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
        libc.mmap.restype = ctypes.c_void_p
        libc.mincore.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_ubyte)]
        libc.mincore.restype = ctypes.c_int
        libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        libc.munmap.restype = ctypes.c_int
        address = libc.mmap(None, stat.st_size, 0, mmap.MAP_PRIVATE, fd, 0)
        if address == ctypes.c_void_p(-1).value:
            raise OSError(ctypes.get_errno(), "Cannot map executable for cache verification")
        try:
            residency = (ctypes.c_ubyte * pages)()
            if libc.mincore(address, stat.st_size, residency) != 0:
                raise OSError(ctypes.get_errno(), "Cannot query executable cache residency")
            return {"resident_pages": sum(value & 1 for value in residency), "total_pages": pages,
                    "page_size": page_size, "method": "mincore, PROT_NONE mapping"}
        finally:
            libc.munmap(address, stat.st_size)
    finally:
        os.close(fd)


def verify_cold_binary(binary):
    state = binary_cache_state(binary)
    if state["resident_pages"]:
        raise RuntimeError(f"Executable page cache is still warm: {state['resident_pages']}/{state['total_pages']} pages resident after reset. "
                           "No launch was measured. Close processes using this exact executable or rebuild with make profile.")
    return {**state, "verified_cold": True}


def merge_intervals(intervals):
    merged = []
    for start, end in sorted(intervals):
        if end <= start:
            continue
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def interval_time(intervals):
    return sum(end - start for start, end in merge_intervals(intervals))


def subtract_intervals(intervals, excluded):
    """Return uncovered elapsed time, with overlaps counted once."""
    result = []
    excluded = merge_intervals(excluded)
    for start, end in merge_intervals(intervals):
        cursor = start
        for low, high in excluded:
            if high <= cursor:
                continue
            if low >= end:
                break
            if low > cursor:
                result.append((cursor, min(low, end)))
            cursor = max(cursor, min(high, end))
        if cursor < end:
            result.append((cursor, end))
    return result


def account_thread_time(run, ready):
    """Label each lane's uncovered time without pretending it was measured work."""
    signals = {event["name"]: event["start_ns"] for event in reversed(run["events"]) if event["kind"] == "signal"}
    tracks = {event["track"] for event in run["events"] if event["kind"] != "signal"}
    viewport = round(run["metrics"].get("first_document_ms", run["metrics"]["first_frame_ms"]) * 1_000_000)
    gaps, self_spans, summary = [], [], {}
    for track in TRACKS:
        if track not in tracks:
            continue
        calls = [event for event in run["events"] if event["track"] == track and event["kind"] != "signal"]
        intervals = [(event["start_ns"], event["start_ns"] + event["duration_ns"]) for event in calls]
        main_entry = run.get("main_entry_ns", 0)
        cuts = sorted({0, main_entry, ready, viewport, *signals.values()})
        for start, end in subtract_intervals([(0, ready)], intervals):
            boundaries = [start, *(at for at in cuts if start < at < end), end]
            for low, high in zip(boundaries, boundaries[1:]):
                kind = "untraced"
                name = f"Untraced {track} dispatch / scheduling"
                if track == "launch":
                    kind, name = "idle", "Application running"
                elif track == "gui" and high <= main_entry:
                    kind, name = "idle", "Before main entry"
                elif track == "gui" and low == 0:
                    name = "Untraced startup / GUI setup"
                elif track in ("document", "navigation", "images", "fallback", "input") or (track == "fonts" and "Request system monospace" in signals):
                    request = signals.get({"document": "Request document", "navigation": "Request navigation", "images": "Request image decoding", "fonts": "Request system monospace", "fallback": "Request system Sans fallback", "input": "Request keyboard preparation"}[track])
                    finished = signals.get({"document": "Document ready", "navigation": "Navigation ready", "images": "Images ready", "fonts": "System monospace prepared", "fallback": "System Sans fallback prepared", "input": "Keyboard preparation ready"}[track])
                    if request is not None and high <= request:
                        kind = "idle"
                        name = "Deferred — first viewport" if track in ("navigation", "fonts", "fallback") and request >= viewport and high <= viewport else "Not requested yet"
                    elif finished is not None and low >= finished:
                        kind = "idle"
                        name = f"Idle — {track} ready"
                if gaps and gaps[-1]["track"] == track and gaps[-1]["name"] == name and gaps[-1]["start_ns"] + gaps[-1]["duration_ns"] == low:
                    gaps[-1]["duration_ns"] += high - low
                    gaps[-1]["self_ns"] += high - low
                else:
                    gaps.append({"id": f"gap-{track}-{len(gaps)}", "name": name, "track": track, "kind": kind,
                                 "start_ns": low, "duration_ns": high - low, "self_ns": high - low,
                                 "parent": None, "recorded": False})
        waits = [(event["start_ns"], event["start_ns"] + event["duration_ns"]) for event in calls if event["kind"] == "wait"]
        work = [(event["start_ns"], event["start_ns"] + event["duration_ns"]) for event in calls if event["kind"] == "work"]
        summary[track] = {"wait_ms": interval_time(waits) / 1_000_000,
                          "work_ms": interval_time(subtract_intervals(work, waits)) / 1_000_000,
                          **{kind + "_ms": sum(event["duration_ns"] for event in gaps if event["track"] == track and event["kind"] == kind) / 1_000_000 for kind in ("idle", "untraced")}}
    children = defaultdict(list)
    for event in run["events"]:
        if event["parent"] is not None:
            children[event["parent"]].append((event["start_ns"], event["start_ns"] + event["duration_ns"]))
    for event in run["events"]:
        if event["id"] not in children:
            continue
        own_time = subtract_intervals([(event["start_ns"], event["start_ns"] + event["duration_ns"])], children[event["id"]])
        for index, (start, end) in enumerate(own_time):
            self_spans.append({**event, "id": f"self-{event['id']}-{index}", "name": "Self time — " + event["name"],
                               "kind": "self", "parent": event["id"], "start_ns": start, "duration_ns": end - start,
                               "self_ns": end - start, "recorded": False})
    run["gaps"], run["self_spans"], run["thread_summary"] = gaps, self_spans, summary
    for event in gaps:
        if event["kind"] == "untraced":
            prior = max((call for call in run["events"] if call["track"] == event["track"] and call["kind"] != "signal"
                         and call["start_ns"] + call["duration_ns"] <= event["start_ns"]),
                        key=lambda call: call["start_ns"] + call["duration_ns"], default=None)
            following = min((call for call in run["events"] if call["track"] == event["track"] and call["kind"] != "signal"
                             and call["start_ns"] >= event["start_ns"] + event["duration_ns"]),
                            key=lambda call: call["start_ns"], default=None)
            event["before"] = prior["name"] if prior else "Main entry" if event["track"] == "gui" else "Thread start"
            event["after"] = following["name"] if following else "Full readiness"
            event["name"] = "Untraced before " + event["after"]


def startup_dependencies(run):
    """Connect recorded handoffs and the viewer's explicit presentation gates."""
    signals = {}
    for event in run["events"]:
        if event["kind"] == "signal":
            # A Unicode diagram can have an initial Latin-only render and a
            # second render using prepared fallback fonts. Full readiness is
            # gated by the last image handoff, while the initial viewport
            # remains the actual first submitted Markdown frame.
            if event["name"] in ("Request image decoding", "Images ready", "Accept images"):
                signals[event["name"]] = max(signals.get(event["name"], 0), event["start_ns"])
            else:
                signals.setdefault(event["name"], event["start_ns"])
    required = ("Request document", "Document ready", "Accept document",
                "Request navigation", "Navigation ready", "Accept navigation")
    metrics = run["metrics"]
    if any(name not in signals for name in required) or any(name not in metrics for name in ("scaffold_ms", "first_document_ms")):
        return {"nodes": [], "edges": [], "gates": []}
    ns = lambda key: round(metrics[key] * 1_000_000)
    if run.get("startup_policy") == "eager-preparation":
        return eager_startup_dependencies(run, signals, ns)
    nodes = [
        {"id": "start", "label": "Document requested", "track": "gui", "at_ns": signals["Request document"]},
        {"id": "scaffold", "label": "Scaffold presented", "track": "gui", "at_ns": ns("scaffold_ms")},
        {"id": "document", "label": "Document ready", "track": "document", "at_ns": signals["Document ready"]},
        {"id": "accept", "label": "Markdown accepted", "track": "gui", "at_ns": signals["Accept document"]},
        {"id": "viewport", "label": "First viewport", "track": "gui", "at_ns": ns("first_document_ms")},
        {"id": "navigation", "label": "Navigation ready", "track": "navigation", "at_ns": signals["Navigation ready"]},
        {"id": "ready", "label": "Fully ready", "track": "gui", "at_ns": ns("first_frame_ms")},
    ]
    if "main_entry_ns" in run:
        nodes.insert(0, {"id": "main-entry", "label": "Pre-load: binary & process initialization", "track": "launch", "at_ns": run["main_entry_ns"],
                         "preload": True, "duration_ns": run["main_entry_ns"]})
    by_id = {node["id"]: node for node in nodes}
    late, early = sorted((by_id["scaffold"], by_id["document"]), key=lambda node: node["at_ns"], reverse=True)
    edges = [{"from": source, "to": target, "kind": kind} for source, target, kind in (
        ("start", "scaffold", "sequence"), ("start", "document", "dispatch"),
        ("scaffold", "accept", "gate"), ("document", "accept", "gate"),
        ("accept", "viewport", "sequence"), ("viewport", "navigation", "deferred"),
        ("navigation", "ready", "handoff"))]
    if "main_entry_ns" in run:
        edges.insert(0, {"from": "main-entry", "to": "start", "kind": "dispatch"})
    gates = [
        {"target": "Markdown acceptance", "blocked_by": late["label"], "track": late["track"],
         "start_ns": early["at_ns"], "end_ns": late["at_ns"],
         "duration_ns": max(0, late["at_ns"] - early["at_ns"]),
         "pickup_ns": max(0, signals["Accept document"] - late["at_ns"])},
        {"target": "Navigation result", "blocked_by": "Navigation worker", "track": "navigation",
         "start_ns": signals["Request navigation"], "end_ns": signals["Navigation ready"],
         "duration_ns": max(0, signals["Navigation ready"] - signals["Request navigation"]),
         "pickup_ns": max(0, signals["Accept navigation"] - signals["Navigation ready"])},
    ]
    # Backtrack the recorded join: the later prerequisite determines Markdown
    # acceptance. Deferred navigation then gates full readiness.
    critical_path = ["start", late["id"], "accept", "viewport", "navigation", "ready"]
    if "main_entry_ns" in run:
        critical_path.insert(0, "main-entry")
    return {"nodes": nodes, "edges": edges, "gates": gates, "last_viewport_gate": late["id"],
            "critical_path": critical_path,
            "navigation_requested_ns": signals["Request navigation"], "navigation_accepted_ns": signals["Accept navigation"]}


def eager_startup_dependencies(run, signals, ns):
    nodes = [
        {"id": "start", "label": "Document requested", "track": "gui", "at_ns": signals["Request document"]},
        {"id": "document", "label": "Document ready", "track": "document", "at_ns": signals["Document ready"]},
        {"id": "accept", "label": "Markdown accepted", "track": "gui", "at_ns": signals["Accept document"]},
        {"id": "window-ready", "label": "Window initialized", "track": "gui", "at_ns": ns("backend_ms")},
        {"id": "scaffold", "label": "First window frame", "track": "gui", "at_ns": ns("scaffold_ms")},
        {"id": "viewport", "label": "First Markdown viewport", "track": "gui", "at_ns": ns("first_document_ms")},
        {"id": "navigation-request", "label": "Navigation requested", "track": "gui", "at_ns": signals["Request navigation"]},
        {"id": "navigation", "label": "Navigation ready", "track": "navigation", "at_ns": signals["Navigation ready"]},
        {"id": "navigation-accept", "label": "Navigation accepted", "track": "gui", "at_ns": signals["Accept navigation"]},
        {"id": "ready", "label": "Fully ready", "track": "gui", "at_ns": ns("first_frame_ms")},
    ]
    edges = [{"from": source, "to": target, "kind": kind} for source, target, kind in (
        ("start", "document", "dispatch"), ("document", "accept", "gate"),
        ("start", "window-ready", "sequence"), ("window-ready", "scaffold", "sequence"),
        ("scaffold", "viewport", "gate"), ("accept", "viewport", "gate"),
        ("accept", "navigation-request", "sequence"), ("navigation-request", "navigation", "dispatch"),
        ("navigation", "navigation-accept", "gate"),
        ("navigation-accept", "ready", "sequence"))]
    by_id = {node["id"]: node for node in nodes}
    late, early = sorted((by_id["scaffold"], by_id["accept"]), key=lambda node: node["at_ns"], reverse=True)
    nav_late = signals["Navigation ready"] > ns("first_document_ms")
    early_adoption = signals["Accept navigation"] < ns("first_document_ms")
    if early_adoption:
        edges.append({"from":"viewport","to":"ready","kind":"gate"})
        critical = ["start"] + (["document", "accept"] if late["id"] == "accept" else ["window-ready", "scaffold"]) + ["viewport", "ready"]
    elif nav_late:
        critical = ["start"] + (["document"] if signals["Document ready"] > ns("backend_ms") else []) + [
            "accept", "navigation-request", "navigation", "navigation-accept", "ready"]
    else:
        critical = ["start"] + (["document", "accept"] if late["id"] == "accept" else ["window-ready", "scaffold"]) + [
            "viewport", "navigation-accept", "ready"]
    if not early_adoption:
        edges.append({"from":"viewport","to":"navigation-accept","kind":"gate"})
    if "main_entry_ns" in run:
        nodes.insert(0, {"id": "main-entry", "label": "Pre-load: binary & process initialization", "track": "launch",
                         "at_ns": run["main_entry_ns"], "preload": True, "duration_ns": run["main_entry_ns"]})
        edges.insert(0, {"from": "main-entry", "to": "start", "kind": "dispatch"})
        critical.insert(0, "main-entry")
    nav_start, nav_end = signals["Request navigation"], signals["Navigation ready"]
    if all(name in signals for name in ("Request image decoding", "Images ready", "Accept images")):
        nodes.extend([
            {"id": "images-request", "label": "Image / diagram preparation requested", "track": "gui", "at_ns": signals["Request image decoding"]},
            {"id": "images", "label": "Image / diagram pixels ready", "track": "images", "at_ns": signals["Images ready"]},
            {"id": "images-accept", "label": "Image / diagram pixels adopted", "track": "gui", "at_ns": signals["Accept images"]},
        ])
        edges.extend({"from": source, "to": target, "kind": kind} for source, target, kind in (
            ("navigation", "images-request", "gate"), ("images-request", "images", "dispatch"),
            ("images", "images-accept", "gate"), ("navigation-accept", "images-accept", "gate"),
            ("images-accept", "ready", "sequence")))
        if signals["Accept images"] < ns("first_document_ms"):
            pass  # The complete UI is already part of the first useful frame.
        elif signals["Images ready"] > max(signals["Accept navigation"], ns("first_document_ms")):
            critical = (["main-entry"] if "main_entry_ns" in run else []) + ["start"] + (["document"] if signals["Document ready"] > ns("backend_ms") else []) + ["accept", "navigation-request", "navigation",
                        "images-request", "images", "images-accept", "ready"]
        else:
            critical.insert(-1, "images-accept")
    latest_font_gate = max(signals["Accept navigation"], signals.get("Accept images", 0), ns("first_document_ms"))
    for key, track, label, presented_label in (
        ("monospace", "fonts", "System monospace", "Monospace code presented"),
        ("fallback", "fallback", "System Sans fallback", "Fallback glyphs presented"),
    ):
        mono_request = signals.get("Request " + label[0].lower() + label[1:])
        mono_adopt = signals.get(label + " adopted", signals.get(label + " unavailable"))
        if mono_request is None or mono_adopt is None:
            continue
        mono_ready = signals.get(label + " prepared")
        available = run["metrics"].get(key + "_status") == "ready"
        nodes.extend([
            {"id":key+"-request", "label":label+" requested after first viewport", "track":"gui", "at_ns":mono_request},
            {"id":key+"-adopt", "label":label+" adopted" if available else label+" unavailable: Open Sans retained", "track":"gui", "at_ns":mono_adopt},
        ])
        edges.extend([{"from":"viewport", "to":key+"-request", "kind":"deferred"},
                      {"from":key+"-adopt", "to":"ready", "kind":"gate"}])
        mono_path = [key+"-request"]
        if mono_ready is not None:
            nodes.append({"id":key, "label":label+" prepared" if available else label+" lookup finished", "track":track, "at_ns":mono_ready})
            edges.extend([{"from":key+"-request", "to":key, "kind":"dispatch"},
                          {"from":key, "to":key+"-adopt", "kind":"gate"}])
            mono_path.append(key)
        else:
            edges.append({"from":key+"-request", "to":key+"-adopt", "kind":"sequence"})
        frame = ns(key+"_frame_ms") if available else None
        if available and frame < ns("first_frame_ms"):
            nodes.append({"id":key+"-frame", "label":presented_label, "track":"gui", "at_ns":frame})
            edges.extend([{"from":key+"-adopt", "to":key+"-frame", "kind":"sequence"},
                          {"from":key+"-frame", "to":"ready", "kind":"gate"}])
        diagram_handoff = (key == "fallback" and signals.get("Request image decoding", -1) >= mono_adopt and
                           any(event["name"] == "Map prepared fallback fonts for diagram labels" for event in run["events"]))
        if diagram_handoff:
            edges.append({"from":key+"-adopt", "to":"images-request", "kind":"gate"})
        font_gate = max(mono_adopt, signals.get("Accept images", 0) if diagram_handoff else 0)
        if font_gate >= latest_font_gate:
            latest_font_gate = font_gate
            critical = (["main-entry"] if "main_entry_ns" in run else []) + ["start"] + (
                ["document", "accept"] if late["id"] == "accept" else ["window-ready", "scaffold"]) + [
                "viewport", *mono_path, key+"-adopt"] + (
                    ["images-request", "images", "images-accept"] if diagram_handoff else
                    [key+"-frame"] if available and frame < ns("first_frame_ms") else []) + ["ready"]
        if available and frame == ns("first_frame_ms"):
            by_id["ready"]["label"] = "Fully ready: " + presented_label.lower()
    # Several milestones can belong to one submitted frame. Keep one visual
    # node instead of drawing fictitious serial stages at the same timestamp.
    aliases = {}
    if ns("scaffold_ms") == ns("first_document_ms"):
        aliases["scaffold"] = "viewport"
        by_id["viewport"]["label"] = "First window + Markdown viewport"
    if ns("first_document_ms") == ns("first_frame_ms"):
        aliases["viewport"] = "ready"
        by_id["ready"]["label"] = ("First window" if ns("scaffold_ms") == ns("first_document_ms") else "Markdown frame") + ": navigation & images ready"
    def resolved(key):
        while key in aliases: key = aliases[key]
        return key
    nodes = [node for node in nodes if node["id"] not in aliases]
    rewritten = []
    for edge in edges:
        edge = {**edge, "from":resolved(edge["from"]), "to":resolved(edge["to"])}
        if edge["from"] != edge["to"] and edge not in rewritten: rewritten.append(edge)
    edges = rewritten
    critical = list(dict.fromkeys(resolved(key) for key in critical))
    return {"policy": "eager-preparation", "nodes": nodes, "edges": edges, "critical_path": critical,
            "last_viewport_gate": late["id"], "navigation_requested_ns": nav_start,
            "navigation_accepted_ns": signals["Accept navigation"],
            "gates": [{"target": "First viewport", "label": "First viewport awaited " + late["label"],
                       "blocked_by": late["label"], "track": late["track"],
                       "start_ns": early["at_ns"], "end_ns": late["at_ns"],
                       "duration_ns": late["at_ns"] - early["at_ns"],
                       "pickup_ns": max(0, ns("first_document_ms") - late["at_ns"])},
                      {"target": "Navigation result", "label": "Navigation preparation overlapped startup",
                       "blocked_by": "Navigation worker", "track": "navigation", "start_ns": nav_start, "end_ns": nav_end,
                       "duration_ns": max(0, nav_end - nav_start),
                       "pickup_ns": max(0, signals["Accept navigation"] - max(nav_end, ns("first_document_ms")))}]}


def call_graph_model(run):
    """Partition elapsed time, then follow evidenced worker wake-up handoffs.

    Outer blocks never overlap on a thread. A worker replaces a GUI interval
    on the counted path only when its result arrives during a measured GUI
    wait and no independent GUI work delays its adoption. Untraced intervals
    stay on the GUI path rather than acquiring an invented blocking cause.
    """
    full = round(run["metrics"]["first_frame_ms"] * 1_000_000)
    viewport = round(run["metrics"].get("first_document_ms", run["metrics"]["first_frame_ms"]) * 1_000_000)
    entry = run.get("main_entry_ns", 0)
    events = run["events"]
    calls = [e for e in events if e["kind"] != "signal" and e["duration_ns"] > 0]
    roots = [e for e in calls if e.get("parent") is None]
    gui_roots = [e for e in roots if e["track"] == "gui"]
    signals = [e for e in events if e["kind"] == "signal"]
    end = lambda e: e["start_ns"] + e["duration_ns"]
    definitions = (
        ("document", "Request document", "Document ready", "Accept document", "Accept loaded document"),
        ("navigation", "Request navigation", "Navigation ready", "Accept navigation", "Apply table of contents"),
        ("images", "Request image decoding", "Images ready", "Accept images", "Adopt decoded image pixels"),
        ("fonts", "Request system monospace", "System monospace prepared", "System monospace adopted", "Adopt system monospace"),
        ("fallback", "Request system Sans fallback", "System Sans fallback prepared", "System Sans fallback adopted", "Adopt system Sans fallback"),
        ("input", "Request keyboard preparation", "Keyboard preparation ready", "Keyboard resources adopted", "Adopt prepared keyboard resources"),
    )
    tasks = []
    for track, request_name, ready_name, accept_name, scope in definitions:
        requests = [e["start_ns"] for e in signals if e["name"] == request_name]
        for ready_signal in (e for e in signals if e["name"] == ready_name):
            ready = ready_signal["start_ns"]
            request = max((at for at in requests if at <= ready), default=None)
            accepted = min((e["start_ns"] for e in signals if e["name"] == accept_name and e["start_ns"] >= ready), default=None)
            if request is None or accepted is None:
                continue
            receiver = next((e for e in gui_roots if e["start_ns"] <= accepted <= end(e)), None)
            candidates = [e for e in calls if e["track"] == "gui" and e["name"].startswith(scope)
                          and ready <= e["start_ns"] <= accepted and
                          (receiver is None or receiver["start_ns"] <= e["start_ns"] <= end(receiver))]
            consumer = min((e["start_ns"] for e in candidates), default=receiver["start_ns"] if receiver else accepted)
            consumer = max(ready, consumer)
            waits = [e for e in calls if e["track"] == "gui" and e["kind"] == "wait" and e["start_ns"] <= ready <= end(e)]
            # A compositor-only wake does not establish that this worker
            # blocked the GUI. Older traces need an explicit worker wait name.
            waited = any(e.get("wait", {}).get("reason") == "other descriptor" or
                         (not e.get("wait") and {"document":"document", "navigation":"navigation", "images":"image",
                          "fonts":"monospace", "fallback":"fallback", "input":"keyboard"}[track] in e["name"].lower()) for e in waits)
            bookkeeping = ("Check Wayland events", "Accept document and prepared workers")
            independent = [e for e in gui_roots if e["kind"] == "work" and not e["name"].startswith(bookkeeping)]
            independent += [e for e in calls if e["track"] == "gui" and e.get("parent") is not None and
                            e["name"].startswith(("Adopt ", "Apply table of contents", "Accept loaded document"))]
            busy = any(e["start_ns"] < consumer and end(e) > ready for e in independent)
            other_wait = any(e["track"] == "gui" and e["kind"] == "wait" and e not in waits and
                             e["start_ns"] < consumer and end(e) > ready for e in calls)
            tasks.append({"track": track, "start_ns": request, "end_ns": ready, "consumer_ns": consumer,
                          "accepted_ns": accepted, "blocking": waited and not busy and not other_wait})

    def route(endpoint):
        backwards, cursor = [], endpoint
        while cursor > entry:
            possible = [task for task in tasks if task["blocking"] and task["accepted_ns"] <= cursor
                        and entry <= task["start_ns"] < task["end_ns"] <= cursor]
            if not possible:
                backwards.append({"track":"gui", "start_ns":entry, "end_ns":cursor})
                break
            task = max(possible, key=lambda t: (t["end_ns"], t["consumer_ns"]))
            if task["end_ns"] < cursor:
                backwards.append({"track":"gui", "start_ns":task["end_ns"], "end_ns":cursor})
            backwards.append({"track":task["track"], "start_ns":task["start_ns"], "end_ns":task["end_ns"]})
            cursor = task["start_ns"]
        path = ([{"track":"launch", "start_ns":0, "end_ns":entry}] if entry else []) + list(reversed(backwards))
        assert sum(part["end_ns"]-part["start_ns"] for part in path) == endpoint
        return path

    paths = {"viewport":{"total_ns":viewport, "segments":route(viewport)},
             "ready":{"total_ns":full, "segments":route(full)}}
    cuts = defaultdict(set)
    for path in paths.values():
        for part in path["segments"]:
            cuts[part["track"]].update((part["start_ns"], part["end_ns"]))
    for task in tasks:
        cuts["gui"].update((task["start_ns"], task["consumer_ns"]))
        cuts[task["track"]].update((task["start_ns"], task["end_ns"]))
    cuts["gui"].update((viewport, full))
    tracks = list(dict.fromkeys(["launch", "document", "gui", "input", "fonts", "navigation", "images", "fallback"] +
                               [e["track"] for e in calls]))
    by_id = {e["id"]: e for e in calls}
    descendants = defaultdict(list)
    for event in calls:
        parent = by_id.get(event.get("parent"))
        while parent:
            descendants[parent["id"]].append(event)
            parent = by_id.get(parent.get("parent"))
    nodes = []
    for track in tracks:
        active = [(0, entry)] if track == "launch" and entry else [(entry, full)] if track == "gui" else []
        track_roots = [e for e in roots if e["track"] == track]
        if track not in ("launch", "gui"):
            active += [(task["start_ns"], task["end_ns"]) for task in tasks if task["track"] == track]
            active += [(e["start_ns"], end(e)) for e in track_roots]
        for first, last in merge_intervals(active):
            first, last = max(0, first), min(full, last)
            if last <= first:
                continue
            boundaries = sorted({first, last, *(at for e in track_roots for at in (e["start_ns"], end(e)) if first < at < last),
                                 *(at for at in cuts[track] if first < at < last)})
            for low, high in zip(boundaries, boundaries[1:]):
                root = next((e for e in track_roots if e["start_ns"] <= low and end(e) >= high), None)
                gap = next((e for e in run.get("gaps", []) if e["track"] == track and
                            e["start_ns"] <= low and end(e) >= high), None)
                kind = root["kind"] if root else "untraced"
                label = root["name"] if root else gap["name"] if gap and gap["kind"] == "untraced" else "Worker handoff / untraced interval"
                if track == "launch" and root is None:
                    label = "Pre-load: binary and process initialization"
                rows = []
                if root:
                    for child in descendants[root["id"]]:
                        start, finish = max(low, child["start_ns"]), min(high, end(child))
                        if finish > start:
                            rows.append({"event_id":child["id"], "start_ns":start, "duration_ns":finish-start,
                                         "level":max(0, child["depth"]-root["depth"]-1),
                                         "clipped":start!=child["start_ns"] or finish!=end(child)})
                nodes.append({"id":f"{track}-{low}-{high}", "label":label, "track":track, "kind":kind,
                              "start_ns":low, "duration_ns":high-low, "event_id":root["id"] if root else None,
                              "clipped":bool(root and (low!=root["start_ns"] or high!=end(root))), "rows":rows})
    for endpoint, label in ((viewport, "First Markdown viewport"), (full, "Fully ready")):
        if any(n.get("milestone") and n["start_ns"] == endpoint for n in nodes):
            nodes[-1]["label"] = "First viewport and fully ready"
        else:
            nodes.append({"id":f"milestone-{endpoint}", "label":label, "track":"gui", "kind":"signal",
                          "start_ns":endpoint, "duration_ns":0, "milestone":True, "event_id":None, "rows":[]})
    nodes.sort(key=lambda n: (n["start_ns"]+n["duration_ns"], not bool(n["duration_ns"]), n["track"]))
    edges = []
    def connect(source, target, kind):
        if source and target and source["id"] != target["id"]:
            edge = {"from":source["id"], "to":target["id"], "kind":kind}
            if not any(e["from"] == edge["from"] and e["to"] == edge["to"] for e in edges):
                edges.append(edge)
    for track in tracks:
        sequence = [n for n in nodes if n["track"] == track]
        for source, target in zip(sequence, sequence[1:]):
            connect(source, target, "sequence")
    def before(track, at):
        return max((n for n in nodes if n["track"] == track and n["start_ns"]+n["duration_ns"] <= at),
                   key=lambda n: (n["start_ns"]+n["duration_ns"], n["start_ns"]), default=None)
    def after(track, at):
        return min((n for n in nodes if n["track"] == track and n["start_ns"] >= at),
                   key=lambda n: (n["start_ns"], not bool(n["duration_ns"])), default=None)
    if entry:
        connect(before("launch", entry), after("gui", entry), "handoff")
    for task in tasks:
        connect(before("gui", task["start_ns"]), after(task["track"], task["start_ns"]), "dispatch")
        connect(before(task["track"], task["end_ns"]), after("gui", task["consumer_ns"]), "handoff")
    for name, path in paths.items():
        counted = [node for node in nodes if node["duration_ns"] and any(
            node["track"] == part["track"] and part["start_ns"] <= node["start_ns"] and
            node["start_ns"]+node["duration_ns"] <= part["end_ns"] for part in path["segments"])]
        markers = [node for node in nodes if node.get("milestone") and node["start_ns"] <= path["total_ns"] and any(
            part["track"] == node["track"] and part["start_ns"] <= node["start_ns"] <= part["end_ns"] for part in path["segments"])]
        counted += markers
        counted.sort(key=lambda n: (n["start_ns"], not n.get("milestone", False)))
        assert sum(n["duration_ns"] for n in counted) == path["total_ns"], "Critical path does not conserve elapsed time"
        assert all(a["start_ns"]+a["duration_ns"] == b["start_ns"] for a,b in zip(counted,counted[1:])), "Critical path has a gap or overlap"
        path["node_ids"] = [n["id"] for n in counted]
        for source, target in zip(counted, counted[1:]):
            connect(source, target, "critical handoff")
    return {"nodes":nodes, "edges":edges, "paths":paths, "t0":"launch" if entry else "main"}


def analyze_run(run):
    """Build nested calls and parallel windows without counting a thread twice."""
    if run.get("profile_version") != 1:
        raise ValueError("The binary does not support startup profile format 1.")
    ready = round(run["metrics"]["first_frame_ms"] * 1_000_000)
    timing = run['metrics']
    if 'first_document_commit_ms' in timing:
        viewport = timing.get('first_document_ms', timing['first_frame_ms'])
        if timing['first_document_commit_ms'] > viewport + .000001:
            raise ValueError('Viewport callback preceded its actual Markdown buffer commit')
        if 'first_document_flush_ms' in timing and not timing['first_document_commit_ms'] <= timing['first_document_flush_ms'] <= viewport + .000001:
            raise ValueError('Viewport callback preceded its actual Wayland socket flush')
    if timing.get('diagram_module_loaded'):
        viewport = timing.get('first_document_ms', timing['first_frame_ms'])
        if not viewport < timing.get('diagram_module_ready_ms', 0) <= timing['first_frame_ms']:
            raise ValueError('Diagram module must load after the first viewport and before readiness')
    if ready <= 0 or not run.get("events"):
        raise ValueError("The profile has no completed startup spans.")
    events = []
    for event in run["events"]:
        if (event["track"] not in TRACKS or event["kind"] not in ("work", "wait", "signal")
                or min(event["start_ns"], event["duration_ns"], event["depth"]) < 0
                or (event["kind"] == "signal" and event["duration_ns"] != 0)):
            raise ValueError("The profile contains an invalid span.")
        start = event["start_ns"]
        if start <= ready:
            source = event["source"].replace(str(Path(__file__).resolve().parents[1]) + "/", "")
            events.append({**event, "source": source, "duration_ns": min(ready - start, event["duration_ns"])})
    events.sort(key=lambda event: (event["start_ns"], event["depth"], -event["duration_ns"]))
    stacks, children, work = defaultdict(list), defaultdict(list), defaultdict(list)
    wait_intervals = defaultdict(list)
    waits = []
    for index, event in enumerate(events):
        event["id"], event["parent"] = index, None
        start, end = event["start_ns"], event["start_ns"] + event["duration_ns"]
        if event["kind"] == "signal":
            event["self_ns"] = 0
            continue
        stack = stacks[event["track"]]
        while stack and (stack[-1]["depth"] >= event["depth"] or
                         stack[-1]["start_ns"] + stack[-1]["duration_ns"] < end):
            stack.pop()
        if stack:
            event["parent"] = stack[-1]["id"]
            children[stack[-1]["id"]].append((start, end))
        stack.append(event)
        if event["kind"] == "work":
            work[event["track"]].append((start, end))
        elif event["kind"] == "wait":
            wait_intervals[event["track"]].append((start, end))
            if event["track"] == "gui":
                waits.append((start, end))
    for event in events:
        event["self_ns"] = max(0, event["duration_ns"] - interval_time(children[event["id"]]))
    changes = defaultdict(list)
    for track, intervals in work.items():
        for start, end in subtract_intervals(intervals, wait_intervals[track]):
            changes[start].append((track, True))
            changes[end].append((track, False))
    changes.setdefault(0, [])
    changes.setdefault(ready, [])
    active, activity, groups = set(), [], []
    previous = serial = parallel = untraced = 0
    for point, updates in sorted(changes.items()):
        duration = point - previous
        if duration:
            activity.append({"start_ns": previous, "duration_ns": duration, "tracks": sorted(active)})
            if len(active) >= 2:
                parallel += duration
                if groups and groups[-1]["start_ns"] + groups[-1]["duration_ns"] == previous:
                    groups[-1]["duration_ns"] += duration
                    groups[-1]["tracks"] = sorted(set(groups[-1]["tracks"]) | active)
                else:
                    groups.append({"start_ns": previous, "duration_ns": duration, "tracks": sorted(active)})
            elif active:
                serial += duration
            else:
                untraced += duration
        for track, entering in updates:
            if entering:
                active.add(track)
            else:
                active.discard(track)
        previous = point
    run["events"], run["activity"], run["parallel_groups"] = events, activity, groups
    run["concurrency"] = {"one_thread_ms": serial / 1_000_000, "overlap_ms": parallel / 1_000_000,
                          "wait_or_untraced_ms": untraced / 1_000_000, "gui_wait_ms": interval_time(waits) / 1_000_000}
    # Keep the legacy milestone summary for report consumers. The call graph
    # below owns the elapsed-time partition and the counted critical paths.
    run["dependencies"] = startup_dependencies(run)
    account_thread_time(run, ready)
    # A single GUI lane partitions wall time. Unlike sums across concurrent
    # threads or inclusive parents/children, this must reconcile exactly.
    gui = run["thread_summary"].get("gui")
    if gui:
        parts = {key: round(gui[key] * 1_000_000) for key in ("work_ms", "wait_ms", "idle_ms", "untraced_ms")}
        if abs(sum(parts.values()) - ready) > 4:
            raise ValueError("GUI time accounting does not reconcile with full startup.")
        run["wall_accounting"] = {"total_ns": ready, "gui_work_ns": parts["work_ms"],
                                  "gui_wait_ns": parts["wait_ms"], "before_main_ns": parts["idle_ms"],
                                  "untraced_ns": parts["untraced_ms"]}
    run["call_graph"] = call_graph_model(run)
    return run


def timing_stats(values):
    values = sorted(values)
    n = len(values)
    # Two-sided Student-t 95% critical values, df 1..30. Larger samples use
    # the Cornish-Fisher expansion through df^-3; no statistics package needed.
    critical = (12.706205, 4.302653, 3.182446, 2.776445, 2.570582, 2.446912,
                2.364624, 2.306004, 2.262157, 2.228139, 2.200985, 2.178813,
                2.160369, 2.144787, 2.131450, 2.119905, 2.109816, 2.100922,
                2.093024, 2.085963, 2.079614, 2.073873, 2.068658, 2.063899,
                2.059539, 2.055529, 2.051831, 2.048407, 2.045230, 2.042272)
    margin = None
    if n > 1:
        df, z = n - 1, 1.959963984540054
        factor = critical[df - 1] if df <= len(critical) else (
            z + (z**3 + z) / (4 * df) + (5*z**5 + 16*z**3 + 3*z) / (96 * df**2)
            + (3*z**7 + 19*z**5 + 17*z**3 - 15*z) / (384 * df**3))
        margin = factor * statistics.stdev(values) / math.sqrt(n)
    return {"count": n, "mean_ms": statistics.mean(values), "margin_95_ms": margin,
            "min_ms": values[0], "median_ms": statistics.median(values),
            "p95_ms": values[math.ceil(len(values) * .95) - 1], "max_ms": values[-1]}


def launch_orders(document_count, rounds, seed):
    """Counterbalance positions and predecessors without factorial growth.

    For three documents, a cycle contains all six permutations. Every round
    runs each document once, including when the caller requests a partial cycle.
    """
    if document_count < 1 or rounds < 1:
        raise ValueError("Launch order requires at least one document and round.")
    rng = random.Random(seed)
    base = list(range(document_count))
    rng.shuffle(base)
    forward = [tuple(base[i:] + base[:i]) for i in range(document_count)]
    cycle = list(dict.fromkeys(forward + [tuple(reversed(order)) for order in forward]))
    orders = []
    while len(orders) < rounds:
        rng.shuffle(cycle)
        if orders and len(cycle) > 1 and cycle[0] == orders[-1]:
            cycle[0], cycle[1] = cycle[1], cycle[0]
        orders.extend(cycle[:rounds - len(orders)])
    return orders


def include_process_launch(data, started, finished):
    """Align child spans with a parent clock sampled before process creation."""
    main = data.get("main_started_ns")
    if not isinstance(main, int) or main <= 0:
        raise ValueError("The binary has no main-entry timestamp. Rebuild it with make profile.")
    if not started <= main <= finished:
        raise ValueError("The main-entry timestamp does not match the launcher's CLOCK_MONOTONIC interval.")
    offset = main - started
    result = {**data, "metrics": dict(data["metrics"]),
              "events": [{**event, "start_ns": event["start_ns"] + offset} for event in data["events"]]}
    result.pop("main_started_ns")
    metrics = result["metrics"]
    metrics["in_app_viewport_ms"] = metrics.get("first_document_ms", metrics["first_frame_ms"])
    for name in ("first_frame_ms", "full_ready_ms", "first_document_ms", "first_document_commit_ms", "first_document_flush_ms", "scaffold_ms", "window_present_ms", "backend_ms",
                 "diagram_module_ready_ms", "mermaid_module_ready_ms", "svg_module_ready_ms", "first_diagram_ms",
                 "monospace_request_ms", "monospace_adopted_ms", "monospace_frame_ms",
                 "fallback_request_ms", "fallback_adopted_ms", "fallback_frame_ms"):
        if name in metrics:
            metrics[name] += offset / 1_000_000
    ready = round(metrics["first_frame_ms"] * 1_000_000)
    if ready > finished - started:
        raise ValueError("The ready-frame timestamp falls after process exit.")
    metrics["pre_main_ms"] = offset / 1_000_000
    metrics["profiler_exit_ms"] = (finished - started - ready) / 1_000_000
    result["main_entry_ns"] = offset
    result["process_lifecycle_ms"] = (finished - started) / 1_000_000
    result["events"].insert(0, {"name": "Pre-load binary & initialize process", "track": "launch", "kind": "work",
                                "source": "", "function": "External launch timer", "line": 0,
                                "start_ns": 0, "duration_ns": offset, "depth": 0, "boundary": True,
                                "description": "Measured launch request to main entry. Includes process creation, executable and shared-library loading/page faults, ELF mapping, dynamic linking, static initialization and scheduling. This elapsed interval is already included in all launch totals; it is not an isolated disk-I/O timer. Demand paging after main is included in application elapsed time."})
    return result


def document_summary(document, runs):
    return {"document": str(document), "input": file_info(document, document.name), "runs": runs,
            "workload": document_workload(document),
            "statistics": timing_stats([run["metrics"].get("first_document_ms", run["metrics"]["first_frame_ms"]) for run in runs]),
            "scaffold_statistics": timing_stats([run["metrics"].get("scaffold_ms", run["metrics"].get("window_present_ms", run["metrics"]["first_frame_ms"])) for run in runs]),
            "full_ready_statistics": timing_stats([run["metrics"]["first_frame_ms"] for run in runs]),
            "pre_main_statistics": timing_stats([run["metrics"]["pre_main_ms"] for run in runs])}


def document_image_paths(document):
    """Describe local fixture images outside timing; this is not an MD parser.

    Recognizes the inline, full, collapsed and shortcut image forms used by the
    committed fixtures. Fenced examples are excluded. Native parsing remains
    authoritative for the rendered document.
    """
    source = document.read_text()
    source = re.sub(r"^(`{3,}|~{3,})[^\n]*\n.*?^\1[ \t]*$", "", source, flags=re.M | re.S)
    refs = {label.casefold(): target for label, target in re.findall(r"^\[([^\]]+)\]:\s*(\S+)", source, re.M)}
    targets = []
    for match in re.finditer(r'!\[([^\]]*)\](?:\(([^\s)]+)(?:\s+"[^"]*")?\)|\[([^\]]*)\])?', source):
        label, inline, reference = match.groups()
        target = inline or refs.get((reference or label).casefold())
        if target:
            targets.append(target)
    local = [document.parent / target for target in targets if not re.match(r"[a-zA-Z]+:", target)]
    existing = [path for path in local if path.is_file()]
    return targets, local, existing


def document_workload(document):
    targets, local, existing = document_image_paths(document)
    unique = sorted(set(existing))
    return {"image_references": len(targets), "local_images": len(existing),
            "unique_images": len(unique), "missing_images": len(local) - len(existing),
            "png_images": sum(path.suffix.lower() == ".png" for path in unique),
            "jpeg_images": sum(path.suffix.lower() in (".jpg", ".jpeg") for path in unique),
            "asset_bytes": sum(path.stat().st_size for path in unique)}


def cold_input_paths(binary, document):
    return list(dict.fromkeys([binary, document, *document_image_paths(document)[2]]))


def verify_cold_inputs(paths):
    verified = []
    for path in paths:
        if path.stat().st_size:
            try:
                state = verify_cold_binary(path)
            except RuntimeError as error:
                raise RuntimeError(f"Input {path}: {error}") from error
            verified.append({"path": str(path), **state})
    return verified


def atomic_write(destination, text):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=destination.parent, delete=False) as temporary:
        name = Path(temporary.name)
        try:
            temporary.write(text)
            temporary.close()
            name.replace(destination)
        finally:
            name.unlink(missing_ok=True)


def write_report(report, output):
    for document in report.get("documents", [report]):
        for run in document.get("runs", []):
            if "call_graph" not in run:
                run["call_graph"] = call_graph_model(run)
    # Escape HTML delimiters even inside the inert JSON script element.
    payload = json.dumps(report, ensure_ascii=True, separators=(",", ":")).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    template = Path(__file__).with_name("profile.html").read_text()
    atomic_write(output, template.replace("__PROFILE_DATA__", payload))


def timestamped_output(base, now=None):
    stamp = (now or datetime.now(timezone.utc)).astimezone(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    sequence = 0
    while True:
        suffix = f"-{sequence}" if sequence else ""
        candidate = base.with_name(f"{base.stem}-{stamp}{suffix}.html")
        if not any(path.exists() for path in (candidate, candidate.with_suffix(".json"), candidate.with_suffix(".trace.json"))):
            return candidate
        sequence += 1


def require_wayland_session(environment):
    display = Path(environment.get("WAYLAND_DISPLAY") or "wayland-0")
    if not display.is_absolute():
        runtime = environment.get("XDG_RUNTIME_DIR")
        if not runtime:
            raise RuntimeError("Profiling requires a Wayland session. Run make profile from your Wayland desktop.")
        display = Path(runtime) / display
    if not display.is_socket():
        raise RuntimeError(f"Profiling requires a Wayland session. No Wayland display socket is available at {display}.")


def runtime_conditions():
    """Record power/scheduler context before cache reset, outside timed work."""
    affinity = sorted(os.sched_getaffinity(0))
    governors = set()
    for cpu in affinity:
        try:
            value = Path(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/scaling_governor").read_text().strip()
            if value:
                governors.add(value)
        except OSError:
            pass
    return {"cpu_affinity": affinity, "cpu_governors": sorted(governors),
            "load_average": list(os.getloadavg())}


def profile(binary, documents, count, output, seed=None):
    if isinstance(documents, Path):
        documents = [documents]
    if not documents or count < 1:
        raise ValueError("Profiling requires at least one document and one launch per document.")
    output = timestamped_output(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    started_at = datetime.now(timezone.utc).isoformat(timespec="microseconds")
    environment = os.environ.copy()
    environment.pop("MDF_CAPTURE_FRAME", None)
    require_wayland_session(environment)
    # Each measurement creates a fresh connection instead of reusing a caller's
    # pre-opened descriptor. The compositor socket is checked before cache resets.
    environment.pop("WAYLAND_SOCKET", None)
    environment["FLTK_BACKEND"] = "wayland"
    seed = random.SystemRandom().getrandbits(64) if seed is None else seed
    orders = launch_orders(len(documents), count, seed)
    collected = [[] for _ in documents]
    for index, order in enumerate(orders):
        for position, document_index in enumerate(order):
            document, runs = documents[document_index], collected[document_index]
            with tempfile.TemporaryDirectory(prefix=".profile-cache-", dir=output.parent) as cache:
                launch_environment = {**environment, "XDG_CACHE_HOME": cache,
                                      "MESA_SHADER_CACHE_DISABLE": "true", "__GL_SHADER_DISK_CACHE": "0"}
                conditions = runtime_conditions()
                inputs = cold_input_paths(binary, document)
                cache_reset = drop_linux_caches(flush_paths=inputs)
                cache_reset["binary"] = verify_cold_binary(binary)
                cache_reset["inputs"] = verify_cold_inputs(inputs[1:])
                command = [str(binary), "--profile", str(document)]
                started = time.monotonic_ns()
                process = subprocess.run(command, env=launch_environment, capture_output=True, text=True, timeout=45)
                finished = time.monotonic_ns()
            if process.returncode:
                raise RuntimeError(f"{document.name} launch {index + 1} failed ({process.returncode}):\n{process.stderr.strip()}")
            if not process.stdout.strip():
                raise RuntimeError("The viewer closed before the document reached a stable frame.")
            data = json.loads(process.stdout)
            if data.get("mode") != "ReleaseFast":
                raise RuntimeError("The startup profile requires a ReleaseFast build with fully optimized dependencies. Run make profile.")
            if data.get("gui", "").startswith("FLTK") and data.get("ui_mode") != "Release":
                raise RuntimeError("FLTK profiling requires an optimized C++ Release build. Run make profile.")
            if data.get("video_driver") != "wayland":
                raise RuntimeError("The startup profile requires the Wayland video backend.")
            run = analyze_run(include_process_launch(data, started, finished))
            run["stderr"], run["cache_reset"] = process.stderr.strip(), cache_reset
            run["runtime_conditions"] = conditions
            run["launch_sequence"] = {"round": index + 1, "position": position + 1,
                                      "launch": index * len(documents) + position + 1}
            runs.append(run)
            viewport_ms = run["metrics"].get("first_document_ms", run["metrics"]["first_frame_ms"])
            print(f'Cold profile {document.name} {index + 1}/{count} (position {position + 1}/{len(documents)}): {viewport_ms:.2f} ms launch to first viewport, '
                  f'{run["metrics"]["pre_main_ms"]:.2f} ms pre-load, '
                  f'{run["metrics"]["first_frame_ms"]:.2f} ms fully ready', flush=True)
    project = project_context(Path(__file__).resolve().parent.parent, binary, documents[0], collected[0][0])
    project.pop("input", None)
    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "started_at": started_at,
        "cache_policy": "fsync executable, document and local images + Linux drop_caches=3 before every launch; mincore verifies zero resident input pages before timing; unique empty XDG cache; shader disk caches disabled",
        "binary": str(binary), "timing_origin": "parent-before-process-creation",
        "host": platform.platform(), "architecture": platform.machine(), "logical_cpus": os.cpu_count(),
        "tracks": TRACKS, "documents": [document_summary(document, runs) for document, runs in zip(documents, collected)],
        "experiment": {"seed": str(seed), "rounds": count,
                       "order_policy": "Shuffled cycles of cyclic and reversed document orders, balancing positions and predecessors",
                       "round_orders": [[documents[i].name for i in order] for order in orders]},
        "artifacts": {"html": output.name},
        "project": project,
    }
    write_report(report, output)
    print("\nAll-run averages ± 95% margin of error (ms):")
    for document in report["documents"]:
        def estimate(key):
            stats = document[key]
            margin = f' ± {stats["margin_95_ms"]:.2f}' if stats["margin_95_ms"] is not None else ' (margin unavailable)'
            return f'{stats["mean_ms"]:.2f}{margin}'
        print(f'{Path(document["document"]).name} (n={len(document["runs"])}): '
              f'viewport {estimate("statistics")}; pre-load {estimate("pre_main_statistics")}; '
              f'scaffold {estimate("scaffold_statistics")}; ready {estimate("full_ready_statistics")}')
    print(f"Report: {output}")
    return report


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=root / "build/profile/runtime/bin/mdf")
    parser.add_argument("--document", type=Path, action="append", help="Document to measure; repeat to add tabs. Defaults to SAMPLE-SMALL.md, SAMPLE.md, and SAMPLE-HUGE.md.")
    parser.add_argument("--output", type=Path, default=root / "build/profile/profile.html", help="Report base name; a UTC datetime suffix is always added")
    parser.add_argument("--runs", type=int, default=12, help="Cold launches per document (default: 12; two balanced six-order cycles)")
    parser.add_argument("--seed", type=int, help="Reproduce the launch order; otherwise generate and record a random seed")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    try:
        documents = args.document or [root / "SAMPLE-SMALL.md", root / "SAMPLE.md", root / "SAMPLE-HUGE.md"]
        profile(args.binary.resolve(), [path.resolve() for path in documents], args.runs, args.output.resolve(), seed=args.seed)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Profile failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
