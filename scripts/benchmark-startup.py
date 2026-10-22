#!/usr/bin/env python3
"""Paired cold startup comparison of two optimized production executables.

Uses two batches of ten pairs per document by default. No strace, changed
governor, special compiler instrumentation build, or discarded outliers.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import html
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import sys
import tempfile
import time
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('mdf_profile', ROOT/'scripts/profile.py')
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


def estimate(values):
    # Approximate Student-t 95% interval, conservative table for small n.
    n=len(values)
    factor=12.706 if n==2 else 4.303 if n<5 else 2.776 if n<10 else 2.262 if n<20 else 2.093 if n<30 else 2.045 if n<60 else 2.0
    return statistics.mean(values),factor*statistics.stdev(values)/math.sqrt(n) if n>1 else 0


def check_conditions(initial, current):
    if any(current.get(key) != initial.get(key) for key in ('cpu_affinity', 'cpu_governors', 'cpu_power')):
        raise RuntimeError('CPU affinity or power settings changed during the comparison; no mixed-power result is valid.')


def assess(rows, policy='startup'):
    """Apply the agreed selection rule; confidence never excuses a tail regression."""
    failures, uncertain = [], []
    for document in sorted({row['document'] for row in rows}):
        selected = [row for row in rows if row['document'] == document]
        for batch in sorted({row['batch'] for row in selected}):
            group = [row for row in selected if row['batch'] == batch]
            for key, strict in [('first_document_ms', policy == 'startup'), ('scaffold_ms', False)]:
                before = statistics.median(row['before'][key] for row in group)
                after = statistics.median(row['after'][key] for row in group)
                if after > before or (strict and after == before):
                    failures.append(f'{document} batch {batch}: {key} median {before:.3f} → {after:.3f} ms')
        for key in (('first_document_ms', 'scaffold_ms') if policy == 'compressed' else ('first_document_ms', 'first_frame_ms')):
            before = [row['before'][key] for row in selected]
            after = [row['after'][key] for row in selected]
            if profile.timing_stats(after)['p95_ms'] > profile.timing_stats(before)['p95_ms']:
                failures.append(f'{document}: {key} p95 worsened')
            if key == 'first_frame_ms' and statistics.median(after) > statistics.median(before):
                failures.append(f'{document}: fully-ready median worsened')
        saving, margin = estimate([row['before']['first_document_ms']-row['after']['first_document_ms'] for row in selected])
        if policy == 'startup' and saving-margin <= 0: uncertain.append(f'{document}: viewport saving {saving:.3f} ± {margin:.3f} ms')
        for boundary in ('first_document_commit_ms','first_document_flush_ms'):
            if all(boundary in row[v] for row in selected for v in ('before','after')):
                before = statistics.median(row['before'][boundary] for row in selected)
                after = statistics.median(row['after'][boundary] for row in selected)
                if after > before or (policy == 'startup' and after == before):
                    failures.append(f'{document}: actual {boundary} did not improve')
    return {'status': 'rejected' if failures else 'inconclusive' if uncertain else 'retained',
            'reasons': failures or uncertain or [('Scaffold and viewport passed the batch medians, p95 and actual-frame gates; optional rendering readiness is reported separately.' if policy == 'compressed' else 'Both documents passed the median, p95, readiness and paired-confidence gates.')]}


def benchmark(before, after, output, batches, pairs, policy='startup', documents=None,
              compositor_label='Current Wayland desktop'):
    if batches<2 or pairs<2:raise ValueError('Use at least two batches and two pairs per batch.')
    output=profile.timestamped_output(output)
    directory=output.parent/output.stem
    directory.mkdir(parents=True)
    executable=directory/'mdf'
    binaries={'before':before.read_bytes(),'after':after.read_bytes()}
    # Preserve the exact compared ELF/symbols and their common source tree.
    # Later builds must not invalidate a timestamped report's provenance.
    saved={}
    for variant,path in [('before',before),('after',after)]:
        saved[variant]=directory/(variant+'-mdf')
        saved[variant].write_bytes(binaries[variant]);saved[variant].chmod(0o755)
        symbols=path.with_name(path.name+'.debug')
        if symbols.is_file():
            (directory/(variant+'-mdf.debug')).write_bytes(symbols.read_bytes())
        ui_symbols=path.with_name(path.name+'-ui.debug')
        if ui_symbols.is_file():
            (directory/(variant+'-mdf-ui.debug')).write_bytes(ui_symbols.read_bytes())
    with zipfile.ZipFile(directory/'sources.zip','w',zipfile.ZIP_DEFLATED) as bundle:
        for pattern in ('src/*.zig','frontend/*.cpp','frontend/*.hpp','frontend/*.c','frontend/*.h',
                        'frontend/CMakeLists.txt','frontend/core-build.zig','frontend/dependencies.json','frontend/diagram-module.map','frontend/patches/fltk/*',
                        'frontend/pozeiden.zig','frontend/svg.zig','frontend/image-pixels.zig','frontend/launcher.zig','frontend/frontend.map','assets/licenses/*',
                        'modules/pozeiden/**/*.zig','modules/pozeiden/build.zig.zon','modules/pozeiden/**/*.langium','modules/pozeiden/LICENSE','.gitmodules',
                        'modules/zig-svg/**/*.zig','modules/zig-svg/build.zig.zon','modules/zig-svg/LICENSES/*',
                        'modules/zignal/**/*.zig','modules/zignal/build.zig.zon','modules/zignal/LICENSE','scripts/prepare-zignal.py',
                        'tests/text-layout.hpp','tests/cairo.cpp','docs/text-stack.md','docs/cairo.md','scripts/build-cairo.py','scripts/build-text-stack.py','scripts/build-frontend.sh','scripts/prepare-mvzr.py','scripts/prepare-fltk.py','scripts/pack-diagram.py','scripts/pack-frontend.py','scripts/pack-font.py'):
            for path in sorted(ROOT.glob(pattern)):
                if path.is_file():bundle.write(path,path.relative_to(ROOT))
    documents=documents or [ROOT/'SAMPLE.md',ROOT/'SAMPLE-HUGE.md']
    hashes={p:hashlib.sha256(p.read_bytes()).hexdigest() for p in documents}
    environment={**os.environ,'FLTK_BACKEND':'wayland','MESA_SHADER_CACHE_DISABLE':'true','__GL_SHADER_DISK_CACHE':'0'}
    environment.pop('WAYLAND_SOCKET',None)
    environment.pop('MDF_CAPTURE_FRAME',None)
    profile.require_wayland_session(environment)
    initial=profile.runtime_conditions()
    collected={variant:{doc:[] for doc in documents} for variant in binaries}
    rows=[]
    rng=random.Random(82911)
    requested_batches = batches
    target_batches = requested_batches
    for batch in range(requested_batches + 2):
        tasks=[(doc,pair) for doc in documents for pair in range(pairs)]
        rng.shuffle(tasks)
        for doc,pair in tasks:
            # Balance order across batches, including an odd pair count.
            order=['before','after'] if (batch*pairs+pair)%2==0 else ['after','before']
            row={'batch':batch+1,'pair':pair+1,'document':doc.name,'order':order}
            for variant in order:
                conditions=profile.runtime_conditions()
                check_conditions(initial, conditions)
                executable.write_bytes(binaries[variant]);executable.chmod(0o755)
                with tempfile.TemporaryDirectory(prefix='cache-',dir=directory) as cache:
                    inputs=profile.cold_input_paths(executable,doc)
                    reset=profile.drop_linux_caches(flush_paths=inputs)
                    reset['binary']=profile.verify_cold_binary(executable)
                    reset['inputs']=profile.verify_cold_inputs(inputs[1:])
                    started=time.monotonic_ns()
                    process=subprocess.run([str(executable),'--profile',str(doc)],env={**environment,'XDG_CACHE_HOME':cache},
                                           capture_output=True,text=True,timeout=45)
                    finished=time.monotonic_ns()
                final_conditions=profile.runtime_conditions()
                check_conditions(initial, final_conditions)
                if process.returncode:raise RuntimeError(process.stderr)
                raw=json.loads(process.stdout)
                if raw.get('mode')!='ReleaseFast' or raw.get('ui_mode')!='Release' or raw.get('dropped_events'):
                    raise RuntimeError('Expected complete optimized production profiles.')
                measured=profile.analyze_run(profile.include_process_launch(raw,started,finished))
                if 'first_diagram_ms' not in measured['metrics']:
                    rendering=[(e['start_ns']+e['duration_ns'])/1_000_000 for e in measured['events']
                               if e['name'] in ('Render Mermaid diagram','Render SVG image')]
                    if rendering: measured['metrics']['first_diagram_ms']=min(rendering)
                measured.update({'cache_reset':reset,'runtime_conditions':conditions,'runtime_conditions_after':final_conditions,'stderr':process.stderr.strip(),
                                 'batch':batch+1,'pair':pair+1})
                collected[variant][doc].append(measured)
                row[variant]=measured['metrics']
                print(f'{doc.name} batch {batch+1} pair {pair+1}/{pairs} {variant}: {measured["metrics"]["first_document_ms"]:.2f} ms viewport',flush=True)
            shape=lambda variant:tuple(row[variant][key] for key in ('source_bytes','blocks'))
            if shape('before')!=shape('after'):raise RuntimeError('Document workloads differ.')
            rows.append(row)
            # Keep completed pairs reviewable if a long desktop/compositor
            # delay interrupts the batch. This small HTML checkpoint contains
            # metrics only; the final reports retain the complete native spans.
            progress='<html lang="en"><meta charset="utf-8"><title>Incomplete startup comparison</title><h1>Incomplete comparison</h1>'
            progress+='<p>Environment: '+html.escape(compositor_label)+'. Completed pairs only. This is not a final selection result.</p>'
            progress+='<table><tr><th>Batch</th><th>Pair</th><th>Document</th><th>Viewport before, ms</th><th>Viewport after, ms</th><th>Ready before, ms</th><th>Ready after, ms</th></tr>'
            for completed in rows:
                values=[completed['batch'],completed['pair'],completed['document'],
                        *[f'{completed[v][key]:.3f}' for key in ('first_document_ms','first_frame_ms') for v in ('before','after')]]
                progress+='<tr>'+''.join('<td>'+html.escape(str(value))+'</td>' for value in values)+'</tr>'
            profile.atomic_write(directory/'progress.html',progress+'</table></html>')
        print(f'Batch {batch+1}: {pairs} pairs per document complete',flush=True)
        if batch+1 >= target_batches:
            decision = assess(rows,policy)
            if decision['status'] != 'inconclusive' or target_batches > requested_batches: break
            target_batches = requested_batches+2
            print('Paired confidence is inconclusive; collecting two additional batches.',flush=True)
    batches = batch+1
    for doc in documents:
        if hashes[doc]!=hashlib.sha256(doc.read_bytes()).hexdigest():raise RuntimeError('A sample changed during the comparison.')
    links={}
    for variant,binary in [('before',before),('after',after)]:
        project=profile.project_context(ROOT,saved[variant],documents[0],collected[variant][documents[0]][0]);project.pop('input',None)
        target=profile.timestamped_output(output.with_name(output.stem+'-'+variant+'.html'))
        archive={'generated_at':datetime.now(timezone.utc).isoformat(timespec='seconds'),'host':platform.platform(),
                 'logical_cpus':os.cpu_count(),'tracks':profile.TRACKS,'project':project,
                 'compositor':compositor_label,
                 'cache_policy':'Paired untraced optimized launches; fsync all benchmark inputs + drop_caches=3 and mincore zero-page verification before every launch',
                 'documents':[profile.document_summary(doc,collected[variant][doc]) for doc in documents]}
        profile.write_report(archive,target);links[variant]=target.name
    table=[]
    for doc in documents:
        subset=[row for row in rows if row['document']==doc.name]
        for key,label in [('pre_main_ms','Pre-load'),('scaffold_ms','Scaffold'),('first_document_commit_ms','First Markdown buffer commit'),('first_document_flush_ms','First Markdown socket flush'),('first_document_ms','First viewport'),('first_diagram_ms','First diagram pixels'),('first_frame_ms','Fully ready')]:
            if not all(key in r[v] for r in subset for v in ('before','after')):continue
            a=[r['before'][key] for r in subset];b=[r['after'][key] for r in subset]
            delta=[x-y for x,y in zip(a,b)]
            def mean(values):
                center,error=estimate(values);return f'{center:.2f} ± {error:.2f}'
            table.append('<tr>'+''.join('<td>'+html.escape(value)+'</td>' for value in [doc.name,label,mean(a),mean(b),mean(delta),
                         f'{statistics.median(a):.2f} → {statistics.median(b):.2f}',
                         f'{profile.timing_stats(a)["p95_ms"]:.2f} → {profile.timing_stats(b)["p95_ms"]:.2f}', f'{max(a):.2f} → {max(b):.2f}'])+'</tr>')
            print(doc.name,label,'before',mean(a),'after',mean(b),'saving',mean(delta),'ms',flush=True)
    batch_rows=[]
    for batch in range(1,batches+1):
        for doc in documents:
            selected=[r for r in rows if r['batch']==batch and r['document']==doc.name]
            batch_rows.append('<tr>'+''.join(f'<td>{html.escape(str(value))}</td>' for value in [batch,doc.name,
                *[f'{statistics.median([r[v][k] for r in selected]):.2f}' for k in ['scaffold_ms','first_document_ms','first_frame_ms'] for v in ['before','after']]])+'</tr>')
    body='''<!doctype html><meta charset=utf-8><title>MDF paired startup comparison</title><style>body{font:15px system-ui;max-width:1300px;margin:36px auto;padding:0 22px;background:#15202d;color:#e2e9f0}table{width:100%;border-collapse:collapse;margin:18px 0}td,th{padding:9px;text-align:left;border-bottom:1px solid #3b4a5b}p{line-height:1.6}a{color:#8cbaff}details{margin:22px 0}pre{white-space:pre-wrap}</style><h1>Paired optimized startup comparison</h1>'''
    body+=f'<p>{batches} batches × {pairs} pairs per document; {batches*pairs*len(documents)*2} cold launches. Governor: {html.escape(", ".join(initial["cpu_governors"]))}. No tracing; no outliers removed. Positive saving means faster.</p>'
    body+='<p>CPU power settings and affinity were checked before and after every launch: governor, energy preference, frequency limits, turbo/boost, platform profile, and readable power caps. A change aborts the comparison.</p>'
    body+=f'<p><strong>Selection: {decision["status"].upper()}</strong> — '+html.escape(' · '.join(decision['reasons']))+'</p>'
    if any(row['after'].get('rendered_diagrams', 0) > row['before'].get('rendered_diagrams', 0) for row in rows):
        body+='<p>The after build renders Mermaid diagrams; the before build displays their source. Startup totals include this added rendering work.</p>'
    if any(row['after'].get('monospace_status') == 'ready' and 'monospace_status' not in row['before'] for row in rows):
        body+='<p>The after build adds deferred system monospace; the before build keeps Open Sans for code. Both initial viewports use Open Sans. Fully-ready totals include the new font discovery, code reflow and upgraded frame.</p>'
    if any(row['after'].get('fallback_status') == 'ready' and row['before'].get('fallback_status') != 'ready' for row in rows):
        body+='<p>The after build adds deferred system glyph fallback. Both initial viewports use bundled Latin Open Sans. The before build leaves unsupported body characters as boxes; fully-ready totals for the after build include the additional font discovery, script rendering and upgraded frame.</p>'
    body+='<table><tr><th>Document</th><th>Milestone</th><th>Before mean ± margin, ms</th><th>After mean ± margin, ms</th><th>Paired saving ± margin, ms</th><th>Median, ms</th><th>p95, ms</th><th>Maximum, ms</th></tr>'+''.join(table)+'</table>'
    body+='<p>Wayland environment: '+html.escape(compositor_label)+'.</p>'
    if policy == 'compressed':
        body+='<p>This comparison evaluates compressed on-demand rendering. Scaffold and viewport medians and tails must not worsen. First-diagram and fully-ready timings include optional decompression and are reported separately from the initial-frame gates. The original first-diagram timestamp is derived from that same launch’s first completed rendering span.</p>'
    body+='<p>Margins are approximate paired/sample Student-t 95% intervals. Background load and compositor scheduling can correlate samples; these margins are not a guarantee. Both variants use the same file path, settings, Markdown and cache policy. Order is balanced across batches. The same optimized executable used for production emits each native profile; graph times are never imported from another run.</p>'
    body+='<p>'+ ' · '.join(f'<a href="{name}">{variant.title()} native call graphs and individual launches</a>' for variant,name in links.items())+'</p>'
    body+=f'<p>Frozen <a href="{directory.name}/before-mdf">before executable</a>, <a href="{directory.name}/after-mdf">after executable</a>, and <a href="{directory.name}/sources.zip">source snapshot</a> remain with this comparison.</p>'
    body+='<details open><summary>Batch medians, ms</summary><table><tr><th>Batch</th><th>Document</th><th>Window before</th><th>Window after</th><th>Viewport before</th><th>Viewport after</th><th>Ready before</th><th>Ready after</th></tr>'+''.join(batch_rows)+'</table></details>'
    order_rows=[]
    for row in rows:
        values=[row['batch'],row['pair'],row['document'],' → '.join(row['order']),
                *[f'{row[v][k]:.3f}' for k in ['first_document_ms','first_frame_ms'] for v in ['before','after']]]
        order_rows.append('<tr>'+''.join('<td>'+html.escape(str(value))+'</td>' for value in values)+'</tr>')
    body+='<details><summary>Individual pairs and binary identity</summary><table><tr><th>Batch</th><th>Pair</th><th>Document</th><th>Order</th><th>Viewport before</th><th>Viewport after</th><th>Ready before</th><th>Ready after</th></tr>'+''.join(order_rows)+'</table>'
    for variant,binary in binaries.items():body+=f'<p>{variant.title()}: {len(binary):,} bytes · SHA-256 <code>{hashlib.sha256(binary).hexdigest()}</code></p>'
    body+='</details>'
    profile.atomic_write(output,body)
    (directory/'progress.html').unlink(missing_ok=True)
    print('Comparison:',output,flush=True)
    print('Selection:',decision['status'],'; '.join(decision['reasons']),flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before',type=Path,required=True)
    parser.add_argument('--after',type=Path,required=True)
    parser.add_argument('--batches',type=int,default=2)
    parser.add_argument('--pairs-per-batch',type=int,default=10)
    parser.add_argument('--compressed-renderer',action='store_true',help='Gate initial frames; report deferred diagram preparation separately')
    parser.add_argument('--document',type=Path,action='append',help='Override the default two samples; may be repeated for a plain-document control')
    parser.add_argument('--compositor-label',default='Current Wayland desktop',help='Describe the measured Wayland environment in the reports')
    parser.add_argument('--output',type=Path,default=ROOT/'build/startup-experiment/comparison.html')
    args=parser.parse_args()
    benchmark(args.before.resolve(),args.after.resolve(),args.output.resolve(),args.batches,args.pairs_per_batch,
              'compressed' if args.compressed_renderer else 'startup',
              [p.resolve() for p in args.document] if args.document else None,args.compositor_label)


if __name__=='__main__':main()
