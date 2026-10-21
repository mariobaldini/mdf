#!/bin/sh
set -eu
mdf_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$mdf_root"
mdf_binary=${1:-build/fltk-ui/ReleaseFast/mdf}
mdf_binary=$(realpath "$mdf_binary")
mkdir -p build/fltk-tests
mdf_test=$(mktemp -d "$mdf_root/build/fltk-tests/run.XXXXXX")
mkdir -m 700 "$mdf_test/runtime"
cleanup(){ if [ -n "${mdf_weston_pid:-}" ];then kill "$mdf_weston_pid" 2>/dev/null || true;wait "$mdf_weston_pid" 2>/dev/null || true;fi; }
trap cleanup EXIT HUP INT TERM
env -u WAYLAND_DISPLAY -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" \
    LD_PRELOAD="${MDF_TEST_COMPOSITOR_PRELOAD:-${LD_PRELOAD:-}}" \
    weston --backend=headless --renderer=pixman --shell=desktop-shell.so --modules="$mdf_root/build/fltk-tests/virtual-seat.so" --no-config --socket=mdf-test --idle-time=0 --width=1040 --height=780 --log="$mdf_test/weston.log" >"$mdf_test/weston-output.log" 2>&1 &
mdf_weston_pid=$!
mdf_tries=0
while [ ! -S "$mdf_test/runtime/mdf-test" ];do
    mdf_tries=$((mdf_tries+1));if [ "$mdf_tries" -gt 100 ] || ! kill -0 "$mdf_weston_pid" 2>/dev/null;then cat "$mdf_test/weston.log" >&2;exit 1;fi
    sleep 0.05
done
cd "${MDF_TEST_CWD:-$mdf_root}"
env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
    strace -f -e trace=%file,memfd_create,prctl -o "$mdf_test/font-access.log" \
    "$mdf_binary" --self-test --capture "$mdf_test/sample.png" "$mdf_root/SAMPLE.md" >"$mdf_test/gui.log" 2>&1 || { cat "$mdf_test/gui.log" >&2;exit 1; }
cat "$mdf_test/gui.log"
grep -q 'PASS: deferred system monospace:' "$mdf_test/gui.log"
grep -q 'PASS: Latin sample uses bundled glyphs without Sans fallback' "$mdf_test/gui.log"
! grep -q 'mdf-fallback' "$mdf_test/font-access.log"
python3 "$mdf_root/tests/font_access.py" "$mdf_test/font-access.log" --faces 4

# An ordinary text document must keep the completely private startup path.
printf '# Plain document\n\nOnly ordinary body text, café and `inline code`.\n' > "$mdf_test/no-code.md"
env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
    strace -f -e trace=%file,memfd_create,prctl -o "$mdf_test/no-code.trace" \
    "$mdf_binary" --profile "$mdf_test/no-code.md" >"$mdf_test/no-code.log" 2>"$mdf_test/no-code.err"
python3 "$mdf_root/tests/font_access.py" "$mdf_test/no-code.trace" --no-deferred
python3 - "$mdf_test/no-code.log" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
assert data['metrics']['monospace_status']=='not-needed'
assert not data['metrics']['first_viewport_monospace']
assert 'monospace_request_ms' not in data['metrics']
assert data['metrics']['fallback_status']=='not-needed'
assert 'fallback_request_ms' not in data['metrics']
print('PASS: Latin text and inline code never start system font discovery')
PY

# The extended sample owns the fallback workload. Inline code alone must not
# trigger a monospace scan; fenced code remains in the regular sample.
env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
    strace -f -e trace=%file,memfd_create,prctl -o "$mdf_test/scripts.trace" \
    "$mdf_binary" --profile --capture "$mdf_test/scripts.png" "$mdf_root/SAMPLE-EXTENDED.md" >"$mdf_test/scripts.log" 2>"$mdf_test/scripts.err"
python3 "$mdf_root/tests/font_access.py" "$mdf_test/scripts.trace" --faces 4
python3 - "$mdf_test/scripts.log" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]));m=data['metrics']
assert m['monospace_status']=='not-needed' and 'monospace_request_ms' not in m
assert m['fallback_status']=='ready' and not m['first_viewport_fallback']
assert m['first_document_ms'] < m['fallback_request_ms'] <= m['fallback_adopted_ms'] <= m['fallback_frame_ms'] <= m['first_frame_ms']
assert ord('П') in m['fallback_requested_glyphs'] and ord('中') in m['fallback_requested_glyphs']
assert ord('П') not in m['fallback_missing_glyphs']  # Cyrillic installed in the test environment
assert any(e['track']=='fallback' for e in data['events'])
assert not any(e['name']=='Request system monospace' for e in data['events'])
print('PASS: SAMPLE-EXTENDED uses post-viewport Sans fallback without monospace discovery')
PY

# The huge Latin fixture must not acquire a Sans fallback workload either.
env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
    strace -f -e trace=%file,memfd_create,prctl -o "$mdf_test/huge.trace" \
    "$mdf_binary" --profile "$mdf_root/SAMPLE-HUGE.md" >"$mdf_test/huge.log" 2>"$mdf_test/huge.err"
python3 "$mdf_root/tests/font_access.py" "$mdf_test/huge.trace"
python3 - "$mdf_test/huge.log" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]));m=data['metrics']
assert m['fallback_status']=='not-needed' and not m['fallback_requested_glyphs']
assert 'fallback_request_ms' not in m and m['monospace_status']=='ready'
assert not any(e['name']=='Request system Sans fallback' for e in data['events'])
print('PASS: SAMPLE-HUGE stays on bundled glyphs with deferred monospace for code')
PY

# A Latin fenced block starts mono only; it does not need Sans discovery.
printf '# Code\n\n```text\niiii WWWW\n```\n' > "$mdf_test/code-only.md"
env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
    strace -f -e trace=%file,memfd_create,prctl -o "$mdf_test/code-only.trace" \
    "$mdf_binary" --profile "$mdf_test/code-only.md" >"$mdf_test/code-only.log" 2>"$mdf_test/code-only.err"
python3 "$mdf_root/tests/font_access.py" "$mdf_test/code-only.trace"
python3 - "$mdf_test/code-only.log" <<'PY'
import json, sys
m=json.load(open(sys.argv[1]))['metrics']
assert m['monospace_status']=='ready' and m['fallback_status']=='not-needed'
assert not m['first_viewport_monospace'] and 'fallback_request_ms' not in m
print('PASS: a Latin code block starts only the deferred monospace worker')
PY

# Diagram labels receive prepared anonymous font data; the image worker does
# no system font discovery. Mermaid source itself does not request monospace.
printf '# Diagram\n\n```mermaid\nflowchart LR\n A[Привет] --> B[中文]\n```\n' > "$mdf_test/diagram-fonts.md"
env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
    strace -f -e trace=%file,memfd_create,prctl -o "$mdf_test/diagram-fonts.trace" \
    "$mdf_binary" --profile --capture "$mdf_test/diagram-fonts.png" "$mdf_test/diagram-fonts.md" >"$mdf_test/diagram-fonts.log" 2>"$mdf_test/diagram-fonts.err"
python3 "$mdf_root/tests/font_access.py" "$mdf_test/diagram-fonts.trace"
python3 - "$mdf_test/diagram-fonts.log" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]));m=data['metrics']
assert m['monospace_status']=='not-needed' and m['fallback_status']=='ready'
assert m['rendered_diagrams']==1 and m['diagram_errors']==0
assert any(e['name']=='Map prepared fallback fonts for diagram labels' for e in data['events'])
print('PASS: Unicode Mermaid labels use prepared fonts without monospace discovery')
PY

# A system with no usable mono font still completes and keeps readable code.
mkdir -p "$mdf_test/fontconfig/cache"
printf '<fontconfig><cachedir>%s</cachedir></fontconfig>\n' "$mdf_test/fontconfig/cache" > "$mdf_test/fontconfig/empty.conf"
env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
    FONTCONFIG_FILE="$mdf_test/fontconfig/empty.conf" \
    strace -f -e trace=%file,memfd_create,prctl -o "$mdf_test/no-mono.trace" \
    "$mdf_binary" --self-test "$mdf_root/SAMPLE.md" >"$mdf_test/no-mono.log" 2>&1 || { cat "$mdf_test/no-mono.log" >&2;exit 1; }
grep -q 'PASS: deferred monospace unavailable; Open Sans code fallback preserved' "$mdf_test/no-mono.log"
python3 "$mdf_root/tests/font_access.py" "$mdf_test/no-mono.trace" --faces 4
env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
    FONTCONFIG_FILE="$mdf_test/fontconfig/empty.conf" \
    strace -f -e trace=%file,memfd_create,prctl -o "$mdf_test/no-sans.trace" \
    "$mdf_binary" --profile "$mdf_root/SAMPLE-EXTENDED.md" >"$mdf_test/no-sans.log" 2>"$mdf_test/no-sans.err"
python3 "$mdf_root/tests/font_access.py" "$mdf_test/no-sans.trace" --faces 4
python3 - "$mdf_test/no-sans.log" <<'PY'
import json, sys
m=json.load(open(sys.argv[1]))['metrics']
assert m['fallback_status']=='unavailable' and m['fallback_error'] and m['fallback_missing_glyphs']
assert m['monospace_status']=='not-needed'
print('PASS: unavailable system fonts leave explicit missing glyphs in SAMPLE-EXTENDED')
PY
test -z "$(find "$mdf_test/fontconfig/cache" -type f -print -quit)"
printf '%s\n' 'PASS: missing system monospace preserves Open Sans code without creating font caches'
python3 "$mdf_root/tests/frame-submission.py" "$mdf_test"
# SVG uses the same private module, with logical dimensions and readable errors.
cat > "$mdf_test/vector.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120">
<rect width="240" height="120" rx="12" fill="#3676ad"/>
<path d="M20 80 L80 30 L130 80 Z" fill="#ffd36b"/>
<text x="145" y="67" font-size="20" fill="white">MDF SVG</text>
</svg>
SVG
printf '# Local SVG\n\n![Vector image](vector.svg)\n' > "$mdf_test/svg.md"
env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
    strace -f -e trace=%file,memfd_create,prctl -o "$mdf_test/svg.trace" \
    "$mdf_binary" --profile --capture "$mdf_test/svg.png" "$mdf_test/svg.md" >"$mdf_test/svg.log" 2>"$mdf_test/svg.err"
python3 "$mdf_root/tests/font_access.py" "$mdf_test/svg.trace" --no-deferred
cat > "$mdf_test/svg-fonts.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="240" height="80"><text x="8" y="40" font-size="22">Привет</text></svg>
SVG
printf '# SVG and prepared fonts\n\nПривет\n\n![Vector text](svg-fonts.svg)\n' > "$mdf_test/svg-fonts.md"
env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
    "$mdf_binary" --profile --capture "$mdf_test/svg-fonts.png" "$mdf_test/svg-fonts.md" >"$mdf_test/svg-fonts.log" 2>"$mdf_test/svg-fonts.err"
printf '<svg xmlns="http://www.w3.org/2000/svg"><image href="file:///not-loaded.png"/></svg>\n' > "$mdf_test/unsupported.svg"
printf '# Unsupported SVG\n\n![Unsupported vector](unsupported.svg)\n' > "$mdf_test/svg-error.md"
env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
    "$mdf_binary" --profile --capture "$mdf_test/svg-error.png" "$mdf_test/svg-error.md" >"$mdf_test/svg-error.log" 2>"$mdf_test/svg-error.err"
printf '# Ordinary images\n\n![PNG](%s/assets/sample-signal.png)\n\n![JPEG](%s/assets/sample-earthrise.jpg)\n' "$mdf_root" "$mdf_root" > "$mdf_test/raster.md"
env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
    strace -f -e trace=%file,memfd_create,prctl -o "$mdf_test/raster.trace" \
    "$mdf_binary" --profile "$mdf_test/raster.md" >"$mdf_test/raster.log" 2>"$mdf_test/raster.err"
python3 - "$mdf_test" <<'PY'
import json,re,sys
from pathlib import Path
folder=Path(sys.argv[1])
for name in ('no-code','code-only','raster','huge'):
    run=json.loads((folder/(name+'.log')).read_text())
    assert not run['metrics']['diagram_module_loaded'],name
    assert not any(e['name'] in ('Prepare bundled SVG module','Prepare bundled Mermaid module') for e in run['events']),name
    assert all('memfd_create("mdf-'+kind+'"' not in (folder/(name+'.trace')).read_text() for kind in ('svg','mermaid')),name
run=json.loads((folder/'svg.log').read_text());m=run['metrics']
assert m['rendered_svgs']==1 and m['rendered_diagrams']==0 and m['diagram_errors']==0
assert m['monospace_status']=='not-needed' and m['fallback_status']=='not-needed'
assert m['svg_module_loaded'] and not m['mermaid_module_loaded']
assert m['bundled_font_styles']==m['bundled_font_data_styles']==3
assert m['first_document_ms'] < m['diagram_module_ready_ms'] <= m['first_diagram_ms'] <= m['first_frame_ms']
error=json.loads((folder/'svg-error.log').read_text())['metrics']
assert error['diagram_errors']==1 and error['rendered_svgs']==0 and error['diagram_module_loaded']
assert error['monospace_status']=='not-needed'
fonts=json.loads((folder/'svg-fonts.log').read_text())
assert fonts['metrics']['fallback_status']=='ready' and fonts['metrics']['rendered_svgs']==1
assert fonts['metrics']['monospace_status']=='not-needed' and fonts['metrics']['diagram_errors']==0
assert any(e['name']=='Map prepared fallback fonts for diagram labels' for e in fonts['events'])
for name in ('font-access','svg'):
    text=(folder/(name+('.log' if name=='font-access' else '.trace'))).read_text()
    marker=text.index('prctl(PR_SET_NAME, "mdf-viewport"')
    for kind in ('svg','mermaid'):
        calls=list(re.finditer(r'memfd_create\("mdf-'+kind+'"',text))
        assert len(calls)==int(kind=='svg' or name=='font-access'),(name,kind)
        assert all(call.start()>marker for call in calls),(name,kind)
print('PASS: SVG loads only SVG; Mermaid loads layout and SVG once each; ordinary documents skip both modules')
PY

# Parsed emphasis loads exactly the needed face before the first document
# submission. Heading/table-header weight and nested HTML must count too.
printf '# Italic\n\n*Only italic text.*\n' > "$mdf_test/italic.md"
printf '# Bold italic\n\n***Only bold italic text.***\n' > "$mdf_test/bold-italic.md"
printf '# HTML\n\n<em>Italic HTML</em> and <strong><em>both styles</em></strong>.\n' > "$mdf_test/italic-html.md"
printf '# Table\n\n| *Italic heading* | Plain |\n| --- | --- |\n| Text | More |\n' > "$mdf_test/italic-table.md"
for case in small italic bold-italic italic-html italic-table;do
    if [ "$case" = small ];then mdf_doc="$mdf_root/SAMPLE-SMALL.md";else mdf_doc="$mdf_test/$case.md";fi
    env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
        strace -f -e trace=%file,memfd_create,prctl -o "$mdf_test/$case.trace" \
        "$mdf_binary" --profile --capture "$mdf_test/$case.png" "$mdf_doc" >"$mdf_test/$case.log" 2>"$mdf_test/$case.err"
done
python3 - "$mdf_root" "$mdf_test" <<'PY'
import importlib.util,json,sys
from pathlib import Path
root,folder=map(Path,sys.argv[1:])
spec=importlib.util.spec_from_file_location('font_access',root/'tests/font_access.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
for name,mask in [('small',3),('italic',7),('bold-italic',11),('italic-html',15),('italic-table',11)]:
    data=json.loads((folder/(name+'.log')).read_text());m=data['metrics']
    assert m['bundled_font_styles']==m['bundled_font_data_styles']==mask,(name,m)
    assert not m['diagram_module_loaded'] and m['monospace_status']==m['fallback_status']=='not-needed',name
    audit.audit((folder/(name+'.trace')).read_text(),False,mask.bit_count())
    for style,label in [(2,'italic'),(3,'bold italic')]:
        events=[e for e in data['events'] if e['name']=='Decompress Open Sans '+label]
        assert len(events)==int(bool(mask & (1<<style))),(name,label)
        for e in events: assert (e['start_ns']+e['duration_ns'])/1e6 < m['first_document_commit_ms'],name
print('PASS: small text skips italics; Markdown, bold emphasis, HTML and table headers load only actual styles before first pixels')
PY

# Unsupported families retain their fenced source and an error. No SVG
# placeholder or legacy Rust Mermaid renderer may be loaded for these cases.
for kind in journey packet-beta architecture-beta treemap-beta radar-beta zenuml;do
    printf '# Unsupported diagram\n\n```mermaid\n%s\n```\n' "$kind" > "$mdf_test/unsupported-$kind.md"
    env -u WAYLAND_SOCKET XDG_RUNTIME_DIR="$mdf_test/runtime" WAYLAND_DISPLAY=mdf-test \
        "$mdf_binary" --profile --capture "$mdf_test/unsupported-$kind.png" "$mdf_test/unsupported-$kind.md" \
        >"$mdf_test/unsupported-$kind.log" 2>"$mdf_test/unsupported-$kind.err"
done
python3 - "$mdf_test" <<'PY'
import json,sys
from pathlib import Path
for path in Path(sys.argv[1]).glob('unsupported-*.log'):
    data=json.loads(path.read_text());m=data['metrics']
    assert m['mermaid_engine']=='pozeiden' and m['mermaid_module_loaded'] and not m['svg_module_loaded'],path
    assert m['rendered_diagrams']==0 and m['diagram_errors']==1,path
    assert m['monospace_status'] in ('ready','unavailable'),path
    assert not any(event['name']=='Prepare bundled SVG module' for event in data['events']),path
print('PASS: all six unsupported families use source/error view without SVG or a legacy renderer')
PY
python3 "$mdf_root/tests/frame-submission.py" "$mdf_test"
printf 'GUI artifacts: %s\n' "$mdf_test"
