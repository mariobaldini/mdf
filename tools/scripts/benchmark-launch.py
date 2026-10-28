#!/usr/bin/env python3
"""Measure trivial static Zig programs with MDF's external launch timer."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mdf_profile', ROOT/'tools/scripts/profile.py')
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


def measure(binary):
    # Keep the same parent timer, pipes, launch API and text mode as make profile.
    # The child records CLOCK_MONOTONIC before formatting or writing its result.
    started = time.monotonic_ns()
    process = subprocess.run([str(binary)], capture_output=True, text=True, timeout=45)
    finished = time.monotonic_ns()
    if process.returncode or process.stderr:
        raise RuntimeError(f'{binary.name} failed: {process.returncode}: {process.stderr}')
    lines = process.stdout.splitlines()
    if len(lines) != 2 or lines[1] != 'Hello, world!':
        raise RuntimeError('Invalid baseline marker: '+repr(process.stdout))
    reached = int(lines[0])
    if not started <= reached <= finished:
        raise RuntimeError('The parent and child did not use the same monotonic clock')
    return {'parent_start_ns': started, 'point_ns': reached, 'parent_finish_ns': finished,
            'launch_ms': (reached-started)/1e6, 'lifecycle_ms': (finished-started)/1e6}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    version = (ROOT/'.zig-version').read_text().strip()
    cached_zig = ROOT/'zig-pkg'/('zig-'+version)/'zig'
    parser.add_argument('--zig', default=os.environ.get('ZIG', str(cached_zig) if cached_zig.is_file() else 'zig'))
    parser.add_argument('--runs', type=int, default=50, help='Cold launches per executable; each is followed by four warm launches')
    parser.add_argument('--seed', type=int, default=82911)
    parser.add_argument('--output', type=Path, default=ROOT/'build/launch-baseline')
    args = parser.parse_args()
    if sys.platform != 'linux' or platform.machine() != 'x86_64':
        parser.error('The bare entry control currently supports Linux x86_64')
    if args.runs < 2:
        parser.error('Use at least two cold launches per executable')
    actual_version = subprocess.check_output([args.zig, 'version'], text=True).strip()
    if actual_version != version:
        parser.error('Expected Zig '+version+', found '+actual_version)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    directory = args.output.resolve()/('launch-'+stamp)
    directory.mkdir(parents=True)
    sources = directory/'sources'
    sources.mkdir()
    for name in ('hello', 'entry'):
        shutil.copy2(ROOT/'tests/fixtures'/('launch-'+name+'.zig'), sources)
    programs = []
    for name, label in [('hello', 'Zig main'), ('entry', 'Bare Linux entry')]:
        binary = directory/name
        command = [args.zig, 'build-exe', str(sources/('launch-'+name+'.zig')),
                   '-target', 'x86_64-linux-gnu.2.38', '-mcpu=baseline', '-OReleaseFast',
                   '-fllvm', '-flld', '-flto', '-fstrip', '-fno-PIE', '-fno-stack-protector',
                   '--cache-dir', str(ROOT/'build/.zig-cache/launch-baseline'),
                   '--global-cache-dir', str(ROOT/'build/.zig-cache/global'), '-femit-bin='+str(binary)]
        subprocess.run(command, check=True, cwd=ROOT)
        headers = subprocess.check_output(['readelf', '-W', '-l', str(binary)], text=True)
        dynamic = subprocess.check_output(['readelf', '-W', '-d', str(binary)], text=True)
        if 'INTERP' in headers or '(NEEDED)' in dynamic:
            raise RuntimeError('The baseline unexpectedly needs a dynamic loader or shared library')
        (directory/(name+'-elf.txt')).write_text(headers+'\n'+dynamic)
        programs.append({'name': name, 'label': label, 'path': str(binary), 'bytes': binary.stat().st_size,
                         'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'command': command,
                         'shared_libraries': [], 'interpreter': None})
        print(f'Built {label}: {binary.stat().st_size:,} bytes; no libc, interpreter or shared libraries', flush=True)
    report = {'generated_at': datetime.now(timezone.utc).isoformat(), 'compiler': actual_version,
              'host': platform.platform(), 'runtime_conditions': profile.runtime_conditions(),
              'timer': 'Parent CLOCK_MONOTONIC before subprocess.run to child raw CLOCK_MONOTONIC syscall near entry; excludes printing and exit',
              'scope': 'Same Python launcher as make profile; includes parent launch setup, process creation, exec, mapping, faults and scheduling. Excludes shell input/terminal latency.',
              'cache_policy': 'fsync executable + Linux drop_caches=3; mincore must show zero resident executable pages before every cold launch. Warm runs explicitly read and verify all executable pages before timing.',
              'sampling': {'cold_per_program': args.runs, 'warm_per_program': args.runs*4,
                           'order_seed': args.seed, 'outliers_removed': 0}, 'programs': programs, 'runs': []}
    orders = profile.launch_orders(len(programs), args.runs, args.seed)
    for round_index, order in enumerate(orders, 1):
        for position, index in enumerate(order, 1):
            program = programs[index]
            binary = Path(program['path'])
            reset = {key: value for key, value in profile.drop_linux_caches(flush_paths=[binary]).items()
                     if key not in ('xdg_cache', 'shader_cache_environment')}
            reset['binary'] = profile.verify_cold_binary(binary)
            result = measure(binary)
            report['runs'].append({**result, 'program': program['name'], 'cache': 'cold',
                                   'round': round_index, 'position': position, 'cache_reset': reset})
            for repeat in range(4):
                binary.read_bytes()
                state = profile.binary_cache_state(binary)
                if state['resident_pages'] != state['total_pages']:
                    raise RuntimeError('The warm baseline executable was not fully cached')
                result = measure(binary)
                report['runs'].append({**result, 'program': program['name'], 'cache': 'warm',
                                       'round': round_index, 'position': position, 'repeat': repeat+1,
                                       'cache_state': state})
        if round_index % 10 == 0 or round_index == args.runs:
            print(f'Completed {round_index}/{args.runs} balanced rounds ({len(report["runs"])} launches)', flush=True)
    for program in programs:
        program['statistics'] = {}
        for cache in ('cold', 'warm'):
            runs = [r for r in report['runs'] if r['program'] == program['name'] and r['cache'] == cache]
            stats = profile.timing_stats([r['launch_ms'] for r in runs])
            program['statistics'][cache] = {'launch': stats, 'lifecycle': profile.timing_stats([r['lifecycle_ms'] for r in runs])}
            print(f'{program["label"]}, {cache}, n={len(runs)}: mean {stats["mean_ms"]:.4f} ± {stats["margin_95_ms"]:.4f} ms (95%); '
                  f'median {stats["median_ms"]:.4f}; min {stats["min_ms"]:.4f}; p95 {stats["p95_ms"]:.4f}', flush=True)
    destination = directory/'report.json'
    destination.write_text(json.dumps(report, indent=2)+'\n')
    print('Results and exact binaries:', destination, flush=True)


if __name__ == '__main__':
    main()
