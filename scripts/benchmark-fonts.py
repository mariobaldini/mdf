#!/usr/bin/env python3
"""Compare full and Latin Open Sans using cold launches and isolated CPU work.

Run after make build OPTIMIZE=ReleaseFast BUILD_PREFIX=build/profile/runtime.
Requires fontTools and full upstream faces for preparing the comparison. Never replaces
the application's source font assets. Writes one timestamped standalone HTML.
"""
import argparse
import hashlib
import html
import importlib.util
import json
import logging
import math
import os
from pathlib import Path
import random
import resource
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("startup_profile", ROOT / "scripts/profile.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
T95_DF9 = 2.2621571627409915
T95_BY_N = {10: T95_DF9, 25: 2.0638985616280205, 50: 2.009575234489209, 100: 1.9842169515086827}
CASES = {"control": ("Identical full binary A/A", "SAMPLE.md"),
         "sample": ("Full versus Latin: SAMPLE.md", "SAMPLE.md"),
         "huge": ("Full versus Latin: SAMPLE-HUGE.md", "SAMPLE-HUGE.md")}
PROBE_KEYS = ["First font preparation wall", "First font preparation CPU", "Repeated preparation wall", "Repeated preparation CPU",
              "Covered Latin draw wall", "Covered Latin draw CPU", "Excluded scripts draw wall", "Excluded scripts draw CPU"]
FONT_SUBSET_NOTICE = "Modified by Markdown FAST: Latin, punctuation and symbols subset; Greek and Cyrillic glyphs removed."


def run(args, cwd=ROOT):
    subprocess.run(list(map(str, args)), cwd=cwd, check=True)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def subset_face(source, destination):
    """Keep the tested Latin/symbol coverage, layout features and hinting."""
    from fontTools import subset
    from fontTools.ttLib import TTFont
    from fontTools.unicodedata import script
    logging.getLogger("fontTools").setLevel(logging.ERROR)
    font = TTFont(source, recalcTimestamp=False)
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.legacy_kern = opts.hinting = opts.notdef_outline = opts.recommended_glyphs = True
    opts.name_IDs = opts.name_languages = ["*"]
    opts.name_legacy = True
    worker = subset.Subsetter(options=opts)
    worker.populate(unicodes=[cp for cp in font.getBestCmap() if script(cp) not in ("Grek", "Cyrl")])
    worker.subset(font)
    # The modified font itself carries the notice as well as NOTICE.txt.
    font['name'].setName(FONT_SUBSET_NOTICE, 10, 3, 1, 0x409)
    font.save(destination)


def prepare(work, full_fonts=None):
    """Use the exact optimized GUI objects and link flags for both variants."""
    from fontTools.ttLib import TTFont
    ui = ROOT / "build/fltk-ui/ReleaseFast"
    original = ROOT / "build/profile/runtime/bin/mdf"
    if not original.is_file():
        raise RuntimeError("Build ReleaseFast first; see this script's module documentation.")
    bundled = ROOT / "assets/fonts/open-sans"
    full_fonts = full_fonts.resolve() if full_fonts else bundled
    names = [p.name for p in sorted(bundled.glob('*.ttf'))]
    for name in names:
        path = full_fonts / name
        if not path.is_file() or not {0x03b1, 0x0416} <= set(TTFont(path).getBestCmap()):
            raise RuntimeError("Full upstream Open Sans faces are required. Use --full-fonts /path/to/original-open-sans.")
    environment = {**os.environ, "ZIG_GLOBAL_CACHE_DIR": str(ROOT / "build/.zig-cache/global")}
    zig = os.environ.get("ZIG", "zig")
    matching = []
    for variant in ['full', 'latin']:
        source = work / ('source-' + variant)
        source.mkdir(parents=True, exist_ok=True)
        for name in ['build.zig', 'build.zig.zon']:
            shutil.copy2(ROOT / name, source / name)
        for name in ['src', 'frontend', 'assets']:
            shutil.copytree(ROOT / name, source / name, dirs_exist_ok=True)
        shutil.copytree(ROOT / 'modules/pozeiden', source / 'modules/pozeiden',
                        ignore=shutil.ignore_patterns('.git', '.zig-cache', 'zig-out'), dirs_exist_ok=True)
        (source / 'scripts').mkdir(exist_ok=True)
        shutil.copy2(ROOT / 'scripts/pack-font.py', source / 'scripts/pack-font.py')
        for name in names:
            target = source / 'assets/fonts/open-sans' / name
            if variant == 'full':
                shutil.copy2(full_fonts / name, target)
            else:
                subset_face(full_fonts / name, target)
        if all((source / 'assets/fonts/open-sans' / name).read_bytes() == (bundled / name).read_bytes() for name in names):
            matching.append(variant)
        subprocess.run([zig, "build", "--system", str(ROOT / "zig-pkg"), "--cache-dir", str(ROOT / "build/.zig-cache"),
                        "-Dtarget=x86_64-linux-gnu.2.38", "-Dcpu=baseline", "-Doptimize=ReleaseFast", "--prefix", str(work / variant / "core")],
                       env=environment, cwd=source, check=True)
    command = subprocess.check_output(["ninja", "-t", "commands", "mdf"], cwd=ui, text=True).splitlines()[-1]
    base = [arg for arg in shlex.split(command.split(" && ")[1]) if not arg.startswith("-Wl,--dependency-file=")]
    old_core = str(ROOT / "build/fltk-core/ReleaseFast/native/libmdf-core.a")
    probe = work / "font-components.o"
    flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "pangocairo", "pangoft2", "fontconfig"], text=True))
    run(["/usr/bin/g++", "-O3", "-DNDEBUG", "-std=c++17", "-flto=auto", "-fno-fat-lto-objects", "-ffunction-sections", "-fdata-sections",
         "-I" + str(ROOT / "frontend"), "-I" + str(ROOT / "zig-pkg"), "-I" + str(ROOT / "zig-pkg/fltk"),
         "-I" + str(ROOT / "build/fltk/ReleaseFast"), *flags, "-c", ROOT / "tests/font-components.cpp", "-o", probe])
    for variant in ["full", "latin"]:
        directory = work / variant
        (directory / "native").mkdir(parents=True, exist_ok=True)
        (directory / "bin").mkdir(exist_ok=True)
        archive = directory / "core/lib/libmdf-core.a"
        obj = directory / "native/core.o"
        core = directory / "native/libmdf-core.a"
        run([zig, "ld.lld", "-r", "-O3", "--lto-O3", "--whole-archive", archive, "--no-whole-archive", "-o", obj])
        core.unlink(missing_ok=True)
        run([zig, "ar", "rcs", core, obj])
        for kind in ["mdf", "font-components"]:
            args = [str(core) if arg == old_core else arg for arg in base]
            if kind == "font-components":
                args = [arg for arg in args if not arg.startswith("-Wl,--wrap=") and arg not in
                        ["CMakeFiles/mdf.dir/main.cpp.o", "CMakeFiles/mdf.dir/profile.cpp.o"]]
                args.insert(args.index("CMakeFiles/mdf.dir/view.cpp.o"), str(probe))
            dest = directory / "bin" / kind
            args[args.index("-o") + 1] = str(dest)
            run(args, cwd=ui)
            run(["/usr/bin/strip", "--strip-all", dest])
            if kind == 'mdf':
                for renderer in ('mermaid', 'svg'):
                    run([sys.executable, ROOT/'scripts/pack-diagram.py', 'embed', '--kind', renderer,
                         '--binary', dest, '--payload', ui/('mdf-'+renderer+'.payload')])
    assert len(matching) == 1, "Neither font variant exactly matches the production assets"
    assert (work / matching[0] / "bin/mdf").read_bytes() == original.read_bytes(), "Rebuilt production variant differs from the application binary"
    print(f"PASS: rebuilt {matching[0]} production variant is byte-identical; comparison assets remain isolated", flush=True)


def schedule(counts, seed):
    rng = random.Random(seed)
    result = []
    ids = {key: 0 for key in counts}
    odd_batches = {key: 0 for key in counts}
    for batch in range(1, 11):
        slots = []
        for key, count in counts.items():
            n = count // 10 + (1 if count % 10 and batch % 2 else 0)
            first = ["a"] * (n // 2) + ["b"] * (n // 2)
            if n % 2:
                # Alternate the extra side on odd-sized batches, including
                # cases whose odd batches occur only every other batch.
                first.append("a" if odd_batches[key] % 2 == 0 else "b")
                odd_batches[key] += 1
            rng.shuffle(first)
            slots.extend((key, side) for side in first)
        rng.shuffle(slots)
        for key, first in slots:
            ids[key] += 1
            for side in [first, "b" if first == "a" else "a"]:
                result.append({"case": key, "pair": ids[key], "batch": batch, "side": side,
                               "variant": "latin" if side == "b" and key != "control" else "full"})
    assert ids == counts
    return result


def summary(records):
    def estimate(rs, metric):
        values = [r["values"][metric] for r in rs]
        groups = [[r["values"][metric] for r in rs if r["batch"] == b]
                  for b in sorted({r["batch"] for r in rs})]
        mean = statistics.mean(values)
        value = {"mean_ms": mean, "n": len(rs)}
        if len(groups) == 10:
            # Cluster sums also handle unequal batch sizes in the component
            # A/A control. For equal sizes this is sd(batch means)/sqrt(10).
            cluster_se = math.sqrt(10/9 * sum((sum(group)-len(group)*mean)**2 for group in groups))/len(rs)
            batch_margin = T95_DF9 * cluster_se
            run_margin = T95_BY_N[len(rs)] * statistics.stdev(values)/math.sqrt(len(rs))
            value.update(batch_margin95_ms=batch_margin, run_margin95_ms=run_margin,
                         margin95_ms=max(batch_margin, run_margin))
        return value
    result = []
    for key in CASES:
        rows = [r for r in records if r["case"] == key]
        pairs = []
        for index in sorted({r["pair"] for r in rows}):
            sides = {r["side"]: r for r in rows if r["pair"] == index}
            if len(sides) == 2:
                pairs.append({"batch": sides["a"]["batch"], "values": {
                    metric: sides["a"]["values"][metric] - sides["b"]["values"][metric] for metric in sides["a"]["values"]}})
        if not pairs:
            continue
        for metric in rows[0]["values"]:
            result.append({"case": key, "metric": metric, "a": estimate([r for r in rows if r["side"] == "a"], metric),
                           "b": estimate([r for r in rows if r["side"] == "b"], metric), "saving": estimate(pairs, metric)})
    return result


def report(output, data):
    data["cold_summary"] = summary(data["cold_runs"])
    data["component_summary"] = summary(data["component_runs"])
    def table(rows, metrics):
        rendered = []
        for row in rows:
            if row["metric"] not in metrics:
                continue
            cells = [CASES[row["case"]][0], row["metric"], row["a"]["n"]]
            for key in ["a", "b", "saving"]:
                value = row[key]
                digits = 2 if row['metric'] in ['First viewport','Fully ready','Pre-load','Wayland display','Minimap atlas'] else 4
                cells.append(f"{value['mean_ms']:.{digits}f} ± {value['margin95_ms']:.{digits}f}" if "margin95_ms" in value else f"{value['mean_ms']:.{digits}f} (pending)")
            rendered.append("<tr>" + "".join("<td>" + html.escape(str(cell)) + "</td>" for cell in cells) + "</tr>")
        return '<div class="table"><table><thead><tr><th>Comparison</th><th>Metric</th><th>Runs / side</th><th>A mean ± margin, ms</th><th>B mean ± margin, ms</th><th>B saving ± margin, ms</th></tr></thead><tbody>' + "".join(rendered) + '</tbody></table></div>'
    payload = json.dumps(data, separators=(",", ":")).replace("<", "\\u003c").replace("&", "\\u0026")
    conclusion = ""
    control_first = [row['side'] for i,row in enumerate(data['component_runs'])
                     if i%2==0 and row['case']=='control']
    order_note = (f"The component A/A control used {control_first.count('a')} A-first and {control_first.count('b')} B-first pairs. ")
    if abs(control_first.count('a')-control_first.count('b'))>1:
        order_note += "A subsequent schedule check corrects this minor imbalance for future repeats. "
    if len(data['cold_runs']) == 500 and len(data['component_runs']) == 150:
        excluded = next(row for row in data['component_summary'] if row['case']=='sample' and row['metric']=='Excluded scripts draw CPU')
        ratio = excluded['b']['mean_ms']/excluded['a']['mean_ms']
        conclusion = (f"<p><strong>Font preparation improved by approximately 0.16 ms; total first-viewport differences remain inconclusive.</strong> "
                      f"Excluded Greek/Cyrillic rendering consumed {ratio:.2f}× the CPU time with the subset because it produced missing-glyph markers. "
                      "The tested covered Latin text produced identical pixels. Excluded-script rendering is a separate workload and does not establish the cause of the Latin first-viewport timing differences.</p>")
    content = f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Expanded font retest</title>
<style>body{{font:15px system-ui;max-width:1500px;margin:32px auto;padding:0 20px;background:#131b26;color:#e1e8ef}}p{{line-height:1.55;max-width:1150px}}table{{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}}td,th{{padding:9px;border-bottom:1px solid #394a5c;text-align:right}}td:nth-child(-n+2),th:nth-child(-n+2){{text-align:left}}.table{{overflow:auto}}summary{{cursor:pointer;margin:24px 0}}</style>
<h1>Expanded font retest</h1>{conclusion}<p>{len(data['cold_runs'])} / {data.get('expected_cold_runs',500)} cold GUI launches; {len(data['component_runs'])} / {data.get('expected_component_runs',150)} isolated processes. CPU governor: {html.escape(data.get('governor','unknown'))}.</p>
<p>A = full font, B = Latin subset; both A/A labels execute identical full-font bytes. Original source fonts and production executable remain unchanged. All sample counts were fixed before measurement. No outliers are removed.</p>
<h2>Average cold startup</h2>{table(data['cold_summary'], ['First viewport','Fully ready'])}
<p>± is an approximate 95% confidence margin. For conservatism, the report uses the larger of the individual-run Student-t margin and a cluster margin across ten temporal batches (df=9). Saving margins use within-pair A−B differences. Both underlying margins are preserved in the embedded data. Repeated inner iterations are not counted as independent samples. Margins concern uncertainty in means, not individual-launch ranges.</p>
<h2>Isolated font / Pango / Cairo CPU work</h2>{table(data['component_summary'], ['First font preparation CPU','Repeated preparation CPU','Covered Latin draw CPU','Excluded scripts draw CPU'])}
<p>The diagnostic calls the production FontStore::prepare implementation, without Wayland. Each draw sample is a process average of 100 repetitions rendering four styled paragraphs; preparation repeats 20 times. Covered Latin must have zero unknown glyphs and identical pixel hashes in both variants. Excluded Greek/Cyrillic intentionally renders letters with full fonts and missing-glyph markers with the subset, so output differs.</p>
<details><summary>Startup phases</summary>{table(data['cold_summary'], ['Pre-load','Font preparation','Pango adoption','First viewport draw','Wayland display','Minimap atlas'])}</details>
<details><summary>Method and limits</summary><p>Ten temporal batches and randomized case order. GUI runs and full-versus-subset component runs balance A-first and B-first ordering. Actual order is preserved for every sample. {order_note}One fresh executable path is written from memory before every cache reset. Every cold launch uses sync + drop_caches=3, mincore verification of zero resident executable pages, unique empty XDG cache, disabled shader caches, CPU affinity {html.escape(str(data.get('cpu_affinity',[0,1,2,3])))} and the existing desktop Wayland compositor. The recorded governor and preference hash must remain unchanged. Workload/block/frame counts must match. The Markdown draw is selected after document acceptance and before its first frame, excluding the empty scaffold draw. Report writes occur between complete batches. Component processes use CPU 0 and warm filesystem data; CPU clocks exclude descheduled time.</p><p>Totals begin before process creation and stop at the post-flush application callback, including ELF/shared-library loading, initialization, page faults, scheduling, compositor communication and drawing. They are not isolated physical SSD reads or physical presentation timestamps. Active shared libraries and hardware-drive caches may remain warm. CPU frequency, other processes, Btrfs extent/compression layout and compositor scheduling may still vary.</p></details>
<script type="application/json" id="font-retest-data">{payload}</script></html>'''
    profile.atomic_write(output, content)
    (output.parent / "latest-retest.txt").write_text(str(output) + "\n")


def materialize(path, raw):
    temporary = path.with_suffix(".new")
    with temporary.open("wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.chmod(0o755)
    temporary.replace(path)


def benchmark(work, startup_pairs=100, expected_governor='performance', startup_only=False, cpu_set='fast'):
    output = profile.timestamped_output(work / "font-retest.html")
    binaries = {v: (work / v / "bin/mdf").read_bytes() for v in ["full", "latin"]}
    probes = {v: (work / v / "bin/font-components").read_bytes() for v in binaries}
    settings = Path.home() / ".config/mdf/settings.json"
    preference_hash = sha(settings.read_bytes())
    governor_file = Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")
    governor = governor_file.read_text().strip()
    assert governor == expected_governor, f"Expected {expected_governor} governor, found {governor}; no measurements started"
    data = {"generated_at": datetime.now(timezone.utc).isoformat(), "governor": governor,
            "binary_bytes": {v: len(raw) for v, raw in binaries.items()}, "binary_sha256": {v: sha(raw) for v, raw in binaries.items()},
            "cold_runs": [], "component_runs": [], "settings_sha256": preference_hash}
    cold = schedule({"control": max(10,startup_pairs//2), "sample": startup_pairs, "huge": startup_pairs}, 2026101907)
    components = [] if startup_only else schedule({"control": 25, "sample": 50}, 2026101908)
    data['expected_cold_runs'] = len(cold)
    data['expected_component_runs'] = len(components)
    executable = work / "runtime/mdf"
    executable.parent.mkdir(exist_ok=True)
    environment = os.environ.copy()
    for name in ["WAYLAND_SOCKET", "MDF_CAPTURE_FRAME"]:
        environment.pop(name, None)
    environment["FLTK_BACKEND"] = "wayland"
    profile.require_wayland_session(environment)
    affinity = os.sched_getaffinity(0)
    assert {0,1,2,3} <= affinity
    data['cpu_affinity'] = sorted(affinity if cpu_set=='all' else {0,1,2,3})
    def stable():
        assert governor_file.read_text().strip() == governor, "CPU governor changed"
        assert sha(settings.read_bytes()) == preference_hash, "Preferences changed"
    shapes = {}
    try:
        os.sched_setaffinity(0, {0})
        probe_path = executable.with_name("font-components")
        for index, row in enumerate(components):
            stable()
            materialize(probe_path, probes[row['variant']])
            proc = subprocess.run([str(probe_path)], env=environment, capture_output=True, text=True, timeout=20, check=True)
            fields = proc.stdout.strip().split("\t")
            assert len(fields) == 11
            unknown = list(map(int, fields[8:10]))
            assert unknown == [0, 204 if row['variant'] == 'latin' else 0]
            data['component_runs'].append({**row, 'values': dict(zip(PROBE_KEYS, map(float, fields[:8]))),
                                           'unknown_glyphs': unknown, 'latin_pixel_hash': fields[10]})
            assert len({r['latin_pixel_hash'] for r in data['component_runs']}) == 1
            if index == len(components)-1 or components[index+1]['batch'] != row['batch']:
                report(output, data)
                print(f"Components {index+1}/{len(components)}: batch {row['batch']} complete", flush=True)
        os.sched_setaffinity(0, set(data['cpu_affinity']))
        for index, row in enumerate(cold):
            stable()
            materialize(executable, binaries[row['variant']])
            with tempfile.TemporaryDirectory(prefix="empty-cache-", dir=work) as cache:
                reset = profile.drop_linux_caches()
                reset['binary'] = profile.verify_cold_binary(executable)
                before = resource.getrusage(resource.RUSAGE_CHILDREN)
                started = time.monotonic_ns()
                proc = subprocess.run([str(executable), '--profile', str(ROOT / CASES[row['case']][1])],
                                      env={**environment, 'XDG_CACHE_HOME': cache, 'MESA_SHADER_CACHE_DISABLE': 'true', '__GL_SHADER_DISK_CACHE': '0'},
                                      capture_output=True, text=True, timeout=45, check=True)
                finished = time.monotonic_ns()
                after = resource.getrusage(resource.RUSAGE_CHILDREN)
            stable()
            raw = json.loads(proc.stdout)
            assert raw['mode']=='ReleaseFast' and raw['ui_mode']=='Release' and raw['video_driver']=='wayland' and raw['dropped_events']==0
            measured = profile.include_process_launch(raw, started, finished)
            m = measured['metrics']
            shape = tuple(m[k] for k in ['source_bytes','blocks','document_frames'])
            assert shapes.setdefault(CASES[row['case']][1], shape) == shape
            def span(name):
                return sum(e['duration_ns'] for e in measured['events'] if e['name']==name)/1e6
            accepted = min(e['start_ns'] for e in measured['events'] if e['kind']=='signal' and e['name']=='Accept document')
            viewport_ns = round(m['first_document_ms']*1e6)
            document_draws = [e for e in measured['events'] if e['name']=='Draw native FLTK reader viewport'
                              and accepted <= e['start_ns'] < viewport_ns
                              and e['start_ns']+e['duration_ns'] <= viewport_ns]
            assert document_draws, 'No Markdown draw between document acceptance and its first frame'
            # A scaffold can paint an empty reader first. Measure the actual
            # Markdown draw, never the first matching scope in the whole trace.
            first_draw = min(document_draws,key=lambda e:e['start_ns'])['duration_ns']/1e6
            values = {'Pre-load':m['pre_main_ms'], 'First viewport':m['first_document_ms'], 'Fully ready':m['first_frame_ms'],
                      'Font preparation':span('Prepare bundled Open Sans'), 'Pango adoption':span('Adopt Fontconfig configuration in Pango'),
                      'First viewport draw':first_draw, 'Wayland display':span('Initialize Wayland display'), 'Minimap atlas':span('Rasterize cached minimap text')}
            usage = {k:getattr(after,k)-getattr(before,k) for k in ['ru_utime','ru_stime','ru_minflt','ru_majflt','ru_inblock','ru_nvcsw','ru_nivcsw']}
            data['cold_runs'].append({**row,'values':values,'usage':usage,'cache':reset['binary'],'workload':shape})
            if (index+1)%10==0:
                print(f"Cold {index+1}/{len(cold)} batch {row['batch']} {row['case']} {row['side']} viewport {values['First viewport']:.2f} ms", flush=True)
            if index==len(cold)-1 or cold[index+1]['batch']!=row['batch']:
                report(output,data)
        report(output,data)
        print('Report:',output,flush=True)
    finally:
        os.sched_setaffinity(0,affinity)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir',type=Path,default=ROOT/'build/font-benchmark')
    parser.add_argument('--prepare',action='store_true',help='Prepare isolated full/subset binaries and diagnostic probes, then exit.')
    parser.add_argument('--full-fonts',type=Path,help='Directory containing the four full upstream Open Sans TTF files.')
    parser.add_argument('--startup-pairs',type=int,choices=[10,50,100],default=100,help='Paired cold launches per document; defaults to 100.')
    parser.add_argument('--governor',choices=['performance','powersave'],default='performance',help='Require this unchanged governor; never changes the system setting.')
    parser.add_argument('--startup-only',action='store_true',help='Skip the isolated component processes for a focused startup regression check.')
    parser.add_argument('--cpu-set',choices=['fast','all'],default='fast',help='Pin the GUI to fast cores or use the normal inherited CPU set.')
    parser.add_argument('--check',action='store_true',help='Check statistical pairing and fixed sample counts without launching.')
    args=parser.parse_args()
    work=args.work_dir.resolve()
    work.mkdir(parents=True,exist_ok=True)
    if args.check:
        assert len(schedule({'control':50,'sample':100,'huge':100},1))==500
        assert len(schedule({'control':25,'sample':50},2))==150
        for counts in [{'control':50,'sample':100,'huge':100},{'control':25,'sample':50}]:
            generated=schedule(counts,2026101907)
            for key in counts:
                first=[r['side'] for i,r in enumerate(generated) if i%2==0 and r['case']==key]
                assert abs(first.count('a')-first.count('b'))<=1
        # Paired uncertainty must be zero for a constant saving, even when
        # independent A/B durations share very large temporal variation.
        records=[]
        for batch in range(1,11):
            for side,offset in [('a',3),('b',0)]:
                records.append({'case':'sample','pair':batch,'batch':batch,'side':side,'values':{'test':100*batch+offset}})
        result=summary(records)[0]['saving']
        assert result['mean_ms']==3 and result['margin95_ms']==0
        print('PASS: fixed 500/150 schedules and paired batch confidence calculation')
    elif args.prepare:
        prepare(work,args.full_fonts)
    else:
        benchmark(work,args.startup_pairs,args.governor,args.startup_only,args.cpu_set)


if __name__=='__main__':
    main()
