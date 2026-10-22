#!/usr/bin/env python3
"""Check actual Wayland buffer scaling and fractional protocol events."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    binary = Path(sys.argv[1]).resolve()
    output = ROOT/'build/native-hidpi-tests'
    output.mkdir(exist_ok=True)
    protocols = Path(subprocess.check_output(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], text=True).strip())
    xml = protocols/'staging/fractional-scale/fractional-scale-v1.xml'
    subprocess.run(['wayland-scanner', 'server-header', str(xml), str(output/'fractional-scale-server.h')], check=True)
    subprocess.run(['wayland-scanner', 'private-code', str(xml), str(output/'fractional-scale.c')], check=True)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'libweston-15', 'wayland-server'], text=True).split()
    seat = output/'virtual-seat.so'
    subprocess.run(['/usr/bin/gcc', '-shared', '-fPIC', '-Wno-attributes', '-DMDF_TEST_NATIVE_POINTER', '-DMDF_TEST_NATIVE_FRACTIONAL',
        '-I'+str(output), str(ROOT/'tests/fltk-seat.c'), str(output/'fractional-scale.c'), '-o', str(seat), *flags], check=True)
    rows = []
    with tempfile.TemporaryDirectory(prefix='run-', dir=output) as directory:
        work = Path(directory)
        fonts = work/'fonts.md'
        fonts.write_text('# Scaled fonts\n\nПривет **κόσμε**.\n\n```text\niiii WWWW Привет\n```\n')
        for name, integer, initial, final in [('integer-2x', 2, 240, 240), ('fractional-125', 1, 150, 150), ('fractional-change', 1, 150, 180)]:
            runtime = work/name; runtime.mkdir(mode=0o700)
            env = {**os.environ, 'XDG_RUNTIME_DIR':str(runtime), 'WAYLAND_DISPLAY':'mdf-hidpi', 'MDF_TEST_NATIVE_POINTER':'1'}
            env.pop('WAYLAND_SOCKET', None)
            env.pop('MDF_TEST_NATIVE_FRACTIONAL_SCALE', None)
            env.pop('MDF_TEST_NATIVE_FRACTIONAL_NEXT', None)
            if name.startswith('fractional'):
                env['MDF_TEST_NATIVE_FRACTIONAL_SCALE'] = str(initial)
                if initial != final:
                    env['MDF_TEST_NATIVE_FRACTIONAL_NEXT'] = str(final)
            log_path = output/(name+'-server.log')
            with log_path.open('w') as log:
                server = subprocess.Popen(['weston', '--backend=headless', '--renderer=pixman', '--shell=desktop-shell.so',
                    '--modules='+str(seat), '--no-config', '--socket=mdf-hidpi', '--idle-time=0',
                    '--width='+str(1040*integer), '--height='+str(780*integer), '--scale='+str(integer)],
                    env=env, stdout=log, stderr=subprocess.STDOUT)
                try:
                    for _ in range(100):
                        if (runtime/'mdf-hidpi').is_socket(): break
                        assert server.poll() is None, log_path.read_text()
                        time.sleep(.05)
                    else: raise RuntimeError('No isolated HiDPI compositor socket')
                    for case, document, mode in [('small', ROOT/'SAMPLE-SMALL.md', '--ready-ui'),
                        ('fonts', fonts, '--ready-ui'), ('sample', ROOT/'SAMPLE.md', '--ready-ui'), ('frame', ROOT/'SAMPLE-SMALL.md', '--test-frame'),
                        ('selection', ROOT/'SAMPLE-SMALL.md', '--test-selection')]:
                        capture = output/(name+'-'+case+'.png')
                        child_env = {**env}
                        if case == 'sample': child_env['MDF_NATIVE_TEST_ANCHOR'] = 'mermaid-diagram'
                        run = subprocess.run([str(binary), str(document), str(capture), mode], cwd=ROOT,
                            env=child_env, capture_output=True, text=True, timeout=35)
                        assert run.returncode == 0, (name, case, run.stderr)
                        result = json.loads(run.stdout)
                        assert result['scale120'] == final and result['requested_scale120'] == final, result
                        assert result['fractional_viewport'] == name.startswith('fractional'), result
                        assert result['pixel_width'] == (result['width']*final+119)//120, result
                        assert result['pixel_height'] == (result['height']*final+119)//120, result
                        data = capture.read_bytes()
                        assert struct.unpack_from('>II', data, 16) == (result['pixel_width'], result['pixel_height'])
                        if name == 'fractional-change':
                            assert result['first_viewport_scale120'] == initial and result['paints'] >= 2, result
                        if case == 'small':
                            assert (result['body']['width'], result['body']['height']) == (676,682), result
                            assert not result['fonts']['module_loaded'] and not result['assets']['worker_started'], result
                            assert result['minimap']['finished'] and result['minimap']['lines'] > 0 and not result['minimap']['error_message'], result
                        elif case == 'fonts':
                            text = result['fonts']; widths = text['code_widths']
                            assert text['mono_ready'] and text['sans_ready'] and text['unresolved'] == 0, result
                            assert result['minimap']['font_version'] == text['sans_version'] > 0, result
                            assert widths['narrow'] > 0 and abs(widths['narrow']-widths['wide']) < .1, result
                        elif case == 'frame':
                            assert result['frame_stage'] == 3 and result['cursor_commits'] > 0, result
                            assert result['cursor_scale'] == (final+119)//120, result
                            assert (result['width'], result['height']) == (800,600) and result['selected_bytes'] > 0, result
                        elif case == 'sample':
                            assert result['assets']['counts'] == {'raster':5, 'svg':0, 'mermaid':1, 'failures':0}, result
                            assert result['scroll'] > 0 and result['fonts']['mono_ready'], result
                        else:
                            assert 0 < result['selected_bytes'] < 100, result
                        result['case'] = name+'-'+case; rows.append(result)
                finally:
                    server.terminate()
                    try: server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        server.kill(); server.wait()
            if name.startswith('fractional'):
                assert 'MDF_TEST_FRACTIONAL_INITIAL='+str(initial) in log_path.read_text()
                if initial != final:
                    assert 'MDF_TEST_FRACTIONAL_NEXT='+str(final) in log_path.read_text()
    (output/'results.json').write_text(json.dumps(rows, indent=2)+'\n')
    print('PASS: native 2x and fractional buffers, protocol scale changes, logical layout, system text, selection and cursor sizing')


if __name__ == '__main__':
    main()
