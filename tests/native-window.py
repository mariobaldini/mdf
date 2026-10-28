#!/usr/bin/env python3
"""Exercise actual native Wayland mapping and the compositor frame callback."""
import json
import importlib.util
import shutil
import os
import select
import struct
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
profile_spec=importlib.util.spec_from_file_location('mdf_profile',ROOT/'tools/scripts/profile.py')
profile=importlib.util.module_from_spec(profile_spec)
profile_spec.loader.exec_module(profile)


def png_region(path, box):
    """Read native RGBA PNG pixels independently of the renderer's status."""
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    at = 8
    compressed = bytearray()
    while at < len(data):
        length = struct.unpack_from('>I', data, at)[0]
        kind = data[at+4:at+8]
        content = data[at+8:at+8+length]
        assert zlib.crc32(kind+content) == struct.unpack_from('>I', data, at+8+length)[0]
        if kind == b'IHDR':
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', content)
            assert (depth, color, compression, filtering, interlace) == (8, 6, 0, 0, 0)
        elif kind == b'IDAT':
            compressed.extend(content)
        at += length+12
    stride = width*4
    raw = zlib.decompress(compressed)
    assert len(raw) == height*(stride+1)
    previous = bytearray(stride)
    left, top, right, bottom = box
    region = bytearray()
    for y in range(min(bottom, height)):
        start = y*(stride+1)
        method = raw[start]
        assert method in range(5)
        row = bytearray(raw[start+1:start+1+stride])
        for i in range(stride):
            a = row[i-4] if i >= 4 else 0
            b = previous[i]
            c = previous[i-4] if i >= 4 else 0
            p = a+b-c
            distances = (abs(p-a), abs(p-b), abs(p-c))
            paeth = (a, b, c)[distances.index(min(distances))]
            row[i] = (row[i]+(0, a, b, (a+b)//2, paeth)[method]) & 255
        if y >= top:
            for x in range(left, min(right, width)):
                pixel = row[x*4:x*4+4]
                assert pixel[3] == 255
                region.extend(pixel)
        previous = row
    return bytes(region)


def ink_in_region(path, box):
    region = png_region(path, box)
    return sum(region[i:i+3] != b'\xff\xff\xff' for i in range(0, len(region), 4))


def check_horizontal_overflow(binary, output, environment):
    """Correctness only: readable wrapped columns and all pan input paths."""
    for count in (8,16,24):
        document=output/f'table-{count}.md'
        labels=[f'Column{i+1:02}' for i in range(count)]
        document.write_text('# Wide table\n\nOrdinary prose still wraps in the body while the table scrolls horizontally. '+
            'Readable words must never turn into individual-letter columns.\n\n'+
            '| '+' | '.join(labels)+' |\n| '+' | '.join(['---']*count)+' |\n'+
            '| '+' | '.join([f'Value{i+1:02}' for i in range(count)])+' |\n')
        capture=output/f'table-{count}.png'
        run=subprocess.run([str(binary),str(document),str(capture),'--test-table'],cwd=ROOT,
            env=environment,capture_output=True,text=True,timeout=60)
        assert run.returncode==0,(count,run.stderr)
        result=json.loads(run.stdout)
        assert result['table_stage']==3 and result['paints']==4 and result['ui']['wrap'],result
        assert result['body']['horizontal_overflow'] and result['body']['horizontal_extent']>result['body']['width'],result
        assert result['body']['height']==662 and result['body']['horizontal_scroll']==0,result
        assert ink_in_region(capture,(30,120,430,400))>3000,(count,capture)
        (output/f'table-{count}.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS: wrapped 8/16/24-column tables retain readable widths; keyboard, wheel and body scrollbar reach all columns')


def check_diagrams(binary, output, environment):
    source='```mermaid\nflowchart LR\n A[Open document] --> B[Read Markdown]\n B --> C[Display text]\n C --> D{File changed?}\n D -->|Yes| B\n D -->|No| C\n```\n'
    for name,count,dark in [('light',1,False),('multiple',2,False),('dark',1,True)]:
        document=output/f'diagram-{name}.md'
        document.write_text('# Readable diagram\n\n'+source*count)
        capture=output/f'diagram-{name}.png'
        panned=output/f'diagram-{name}-panned.png'
        run=subprocess.run([str(binary),str(document),str(capture),'--test-diagram-dark' if dark else '--test-diagram'],
            cwd=ROOT,env={**environment,'MDF_NATIVE_TEST_DIAGRAM_PAN_CAPTURE':str(panned.resolve())},
            capture_output=True,text=True,timeout=60)
        assert run.returncode==0,(name,run.stderr)
        result=json.loads(run.stdout)
        assert result['diagram_stage']==6 and result['ui']['wrap'] and result['ui']['dark']==dark,result
        assert result['body']['horizontal_overflow'] and result['body']['horizontal_scroll']==0,result
        assert result['assets']['threads_started']==1 and result['assets']['counts']['mermaid']==count,result
        assert (result['body']['width'],result['body']['height'])==(298,662),result
        assert result['ui']['toc'] and result['ui']['preview'] and result['selected_bytes']==0,result
        assert capture.read_bytes().startswith(b'\x89PNG') and panned.read_bytes().startswith(b'\x89PNG'),name
        assert capture.read_bytes()!=panned.read_bytes(),name
        (output/f'diagram-{name}.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS: readable Mermaid natural size, zoom/Fit/reset, drag/keyboard/bar pan, independent views and pixel reuse in light/dark')


def main():
    binary = Path(sys.argv[1]).resolve()
    debug_smoke='--debug-smoke' in sys.argv[2:]
    tables_only='--tables-only' in sys.argv[2:]
    diagrams_only='--diagrams-only' in sys.argv[2:]
    application=Path(sys.argv[sys.argv.index('--application')+1]).resolve() if '--application' in sys.argv else binary.with_name('mdf-native')
    dependencies = subprocess.check_output(['ldd', str(binary)], text=True)
    assert not any(name in dependencies for name in ('fltk', 'cairo', 'pango', 'libstdc++')), dependencies
    output = ROOT/'build/native-window-tests'
    output.mkdir(exist_ok=True)
    seat = output/'virtual-seat.so'
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'libweston-15', 'wayland-server'], text=True).split()
    subprocess.run(['/usr/bin/gcc', '-shared', '-fPIC', '-Wno-attributes', '-DMDF_TEST_NATIVE_POINTER', str(ROOT/'tests/fltk-seat.c'), '-o', str(seat), *flags], check=True)
    with tempfile.TemporaryDirectory(prefix='run-', dir=output) as directory:
        work = Path(directory)
        runtime = work/'runtime'
        runtime.mkdir(mode=0o700)
        drop_trigger = work/'drop-trigger'
        env = {**os.environ, 'XDG_RUNTIME_DIR': str(runtime), 'WAYLAND_DISPLAY': 'mdf-native-tests', 'MDF_TEST_NATIVE_POINTER': '1',
            'MDF_TEST_NATIVE_DROP_TRIGGER': str(drop_trigger.resolve())}
        env.pop('WAYLAND_SOCKET', None)
        missing = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md')], cwd=ROOT,
            env={**env, 'WAYLAND_DISPLAY': 'mdf-native-unavailable'}, capture_output=True, text=True, timeout=5)
        assert missing.returncode != 0 and 'WaylandUnavailable' in missing.stderr, missing.stderr
        with (work/'weston-output.log').open('w') as log:
            server = subprocess.Popen(['weston', '--backend=headless', '--renderer=pixman', '--shell=desktop-shell.so',
                '--modules='+str(seat),
                '--no-config', '--socket=mdf-native-tests', '--idle-time=0', '--width=1040', '--height=780',
                '--log='+str(work/'weston.log')], env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                for _ in range(100):
                    if (runtime/'mdf-native-tests').is_socket():
                        break
                    assert server.poll() is None, (work/'weston-output.log').read_text()
                    time.sleep(.05)
                else:
                    raise RuntimeError('Weston did not create its socket')
                check_horizontal_overflow(binary,output,env)
                if tables_only:
                    return
                check_diagrams(binary,output,env)
                if diagrams_only:
                    return
                if debug_smoke:
                    for document in ('SAMPLE-SMALL.md','SAMPLE.md'):
                        capture=output/(Path(document).stem+'-debug.png')
                        checked=subprocess.run([str(application),'--profile',str(ROOT/'assets/samples'/document),'--capture',str(capture)],
                            cwd=ROOT,env=env,capture_output=True,text=True,timeout=90)
                        assert checked.returncode==0,(document,checked.stderr)
                        result=json.loads(checked.stdout)
                        assert result['mode']=='Debug' and result['keyboard_ready'] and result['file_browser']['jobs']==0,result
                        assert result['fonts']['finished'] and result['assets']['finished'] and not result['dropped_events'],result
                        assert not result['fonts']['first_viewport_mono'] and not result['fonts']['first_viewport_fallback'],result
                        if document=='SAMPLE.md':assert result['fonts']['mono_ready'] and result['assets']['mermaid_loaded'],result
                        else:assert not result['fonts']['module_loaded'] and not result['assets']['worker_started'],result
                        assert capture.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
                        (output/(Path(document).stem+'-debug.json')).write_text(json.dumps(result,indent=2)+'\n')
                    print('PASS: Debug native bootstrap, keyboard, first-viewport gates, deferred fonts/diagrams and captures')
                    return
                rows = []
                for document in ['SAMPLE-SMALL.md', 'SAMPLE.md', 'SAMPLE-HUGE.md']:
                    capture = output/(Path(document).stem+'.png')
                    started = time.monotonic_ns()
                    run = subprocess.run([str(binary), str(ROOT/'assets/samples'/document), str(capture)], cwd=ROOT,
                        env=env, capture_output=True, text=True, timeout=35)
                    assert run.returncode == 0, (document, run.stderr)
                    result = json.loads(run.stdout)
                    assert result['paints'] == 1, result
                    assert result['width'] > 0 and result['height'] > 0
                    assert 0 <= result['configure_ms'] <= result['commit_ms'] <= result['flush_ms'] <= result['frame_callback_ms']
                    assert result['main_started_ns'] >= started
                    assert capture.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
                    result['document'] = document
                    result['launch_to_commit_ms'] = (result['main_started_ns']-started)/1e6 + result['commit_ms']
                    rows.append(result)
                (output/'results.json').write_text(json.dumps(rows, indent=2)+'\n')
                pending = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'first-dirty.png'), '--test-first-dirty'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert pending.returncode == 0, pending.stderr
                pending_result = json.loads(pending.stdout)
                assert pending_result['paints'] == 1, pending_result
                assert (output/'first-dirty.png').read_bytes() == (output/'SAMPLE-SMALL.png').read_bytes()
                scroll_capture = output/'scroll.png'
                scrolled = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(scroll_capture), '--test-scroll'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert scrolled.returncode == 0, scrolled.stderr
                scrolling = json.loads(scrolled.stdout)
                assert scrolling['paints'] == 6 and scrolling['scroll'] > 0, scrolling
                assert scroll_capture.read_bytes() != (output/'SAMPLE-SMALL.png').read_bytes()
                (output/'scroll.json').write_text(json.dumps(scrolling, indent=2)+'\n')
                selection_capture = output/'selection.png'
                selected = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(selection_capture), '--test-selection'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert selected.returncode == 0, selected.stderr
                selection = json.loads(selected.stdout)
                assert selection['paints'] == 2 and 0 < selection['selected_bytes'] < 100, selection
                assert selection_capture.read_bytes() != (output/'SAMPLE-SMALL.png').read_bytes()
                (output/'selection.json').write_text(json.dumps(selection, indent=2)+'\n')
                details = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE.md'), str(output/'details.png'), '--test-details'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert details.returncode == 0, details.stderr
                toggled = json.loads(details.stdout)
                assert toggled['paints'] == 3 and toggled['details_preserved'], toggled
                (output/'details.json').write_text(json.dumps(toggled, indent=2)+'\n')
                keyboard = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'keyboard.png'), '--test-keyboard'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert keyboard.returncode == 0, keyboard.stderr
                shortcuts = json.loads(keyboard.stdout)
                assert shortcuts['paints'] == 2 and shortcuts['keyboard_ready'] and shortcuts['keyboard_test'], shortcuts
                assert shortcuts['zoom'] > 1 and shortcuts['scroll'] > 0 and shortcuts['selected_bytes'] > 0, shortcuts
                (output/'keyboard.json').write_text(json.dumps(shortcuts, indent=2)+'\n')
                toolbar = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'toolbar.png'), '--test-toolbar'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert toolbar.returncode == 0, toolbar.stderr
                controls = json.loads(toolbar.stdout)
                assert controls['paints'] == 8 and controls['full_ui'], controls
                assert controls['ui'] == {'toc': False, 'preview': False, 'dark': True, 'wrap': False, 'points': 12}, controls
                assert controls['body']['width'] == controls['width']-20 and controls['body']['horizontal_scroll'] > 0, controls
                (output/'toolbar.json').write_text(json.dumps(controls, indent=2)+'\n')
                full = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'full-ui.png'), '--ui'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert full.returncode == 0, full.stderr
                initial_ui = json.loads(full.stdout)
                assert initial_ui['ui']['toc'] and initial_ui['ui']['preview'] and initial_ui['ui']['wrap']
                assert initial_ui['body']['width'] == 676 and initial_ui['body']['height'] == 682, initial_ui
                (output/'full-ui.json').write_text(json.dumps(initial_ui, indent=2)+'\n')
                resize = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'resize.png'), '--test-resize'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert resize.returncode == 0, resize.stderr
                resized = json.loads(resize.stdout)
                assert resized['resize_stage'] == 3 and resized['paints'] >= 3, resized
                assert (resized['resized_width'], resized['resized_height']) != (800, 600), resized
                assert (resized['width'], resized['height']) == (800, 600), resized
                assert resized['selected_bytes'] > 0, resized
                assert (resized['body']['width'], resized['body']['height']) == (508, 502), resized
                (output/'resize.json').write_text(json.dumps(resized, indent=2)+'\n')
                frame = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'frame.png'), '--test-frame'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert frame.returncode == 0, frame.stderr
                framed = json.loads(frame.stdout)
                assert framed['frame_stage'] == 3 and framed['cursor_commits'] > 0, framed
                assert (framed['width'], framed['height']) == (800, 600) and framed['selected_bytes'] > 0, framed
                assert (framed['resized_width'], framed['resized_height']) != (800, 600), framed
                (output/'frame.json').write_text(json.dumps(framed, indent=2)+'\n')
                clipboard = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'clipboard.png'), '--test-clipboard'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert clipboard.returncode == 0, clipboard.stderr
                copied = json.loads(clipboard.stdout)
                assert copied['clipboard_test'] and copied['clipboard_bytes'] == copied['selected_bytes'] > 0, copied
                (output/'clipboard.json').write_text(json.dumps(copied, indent=2)+'\n')
                unicode_document = output/'clipboard-unicode.md'
                unicode_document.write_text('# Copy text\n\nCafé, Привет, 中文, Ελληνικά.\n', encoding='utf-8')
                unicode_copy = subprocess.run([str(binary), str(unicode_document), str(output/'clipboard-unicode.png'), '--test-clipboard'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert unicode_copy.returncode == 0, unicode_copy.stderr
                utf8 = json.loads(unicode_copy.stdout)
                assert utf8['clipboard_test'] and utf8['clipboard_bytes'] == utf8['selected_bytes'] > 50, utf8
                opened_document = output/'opened.md'
                opened_document.write_text('# Native opened file\n\nNew **document** from the Open dialog.\n')
                paste_document = work/'pasted café file.md'
                paste_document.write_text('# Pasted path\n\nOpened from the real Wayland clipboard.\n')
                paste = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'paste.png'), '--test-paste'],
                    cwd=ROOT, env={**env, 'MDF_NATIVE_TEST_OPEN': str(paste_document.resolve())}, capture_output=True, text=True, timeout=35)
                assert paste.returncode == 0, paste.stderr
                pasted = json.loads(paste.stdout)
                assert pasted['paste_stage'] == 4 and pasted['document_revision'] == 2, pasted
                assert pasted['document_path'] == str(paste_document.resolve()) and pasted['status'] == 'Document loaded', pasted
                (output/'paste.json').write_text(json.dumps(pasted, indent=2)+'\n')
                browser_home=work/'browser-home'
                browser_home.mkdir();(browser_home/'sub').mkdir()
                (browser_home/'sub/inside.md').write_text('# Inside\n')
                (browser_home/'.hidden.md').write_text('# Hidden\n')
                for index in range(40):
                    (browser_home/f'{index:02d}-document.md').write_text(f'# Document {index}\n')
                browser_target=browser_home/'z-last 中文.md'
                browser_target.write_text('# Selected from the browser\n\nThe final document is open.\n')
                for name,initial,mode,revision in [('document',str(ROOT/'assets/samples/SAMPLE-SMALL.md'),'--test-browser',1),('empty','','--test-browser-empty',0)]:
                    dialog_capture=output/('browser-'+name+'-dialog.png')
                    browsing=subprocess.run([str(binary),initial,str(output/('browser-'+name+'.png')),mode],cwd=ROOT,
                        env={**env,'HOME':str(browser_home.resolve()),'MDF_NATIVE_TEST_BROWSE':str(browser_home.resolve()),
                            'MDF_NATIVE_TEST_DIALOG_CAPTURE':str(dialog_capture.resolve())},capture_output=True,text=True,timeout=35)
                    assert browsing.returncode==0,(name,browsing.stderr)
                    selected_file=json.loads(browsing.stdout)
                    state=selected_file['file_browser']
                    assert state['stage']==9 and state['initial_revision']==revision and state['scrolled'] and state['jobs']>=6,state
                    assert not state['loading'] and state['entries']==0,state
                    assert selected_file['document_path']==str(browser_target.resolve()) and selected_file['document_revision']==revision+1,selected_file
                    assert not selected_file['fonts']['first_viewport_fallback'] and selected_file['fonts']['sans_ready'] and not selected_file['fonts']['mono_requested'],selected_file
                    assert dialog_capture.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
                    (output/('browser-'+name+'.json')).write_text(json.dumps(selected_file,indent=2)+'\n')
                drop_document = work/'dropped café; file.md'
                drop_document.write_text('# Dropped file\n\nOpened through a negotiated Wayland COPY drop.\n')
                drop = subprocess.Popen([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'drop.png'), '--test-drop'],
                    cwd=ROOT, env={**env, 'MDF_NATIVE_TEST_DROP': '# Local file\r\n'+drop_document.resolve().as_uri()+'\r\n'},
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    drop_trigger.write_text(str(drop.pid))
                    drop_output, drop_error = drop.communicate(timeout=35)
                finally:
                    drop_trigger.unlink()
                    if drop.poll() is None:
                        drop.kill()
                        drop.communicate()
                assert drop.returncode == 0, drop_error
                dropped = json.loads(drop_output)
                assert dropped['drop_stage'] == 2 and dropped['drop_finished'] and dropped['document_revision'] == 2, dropped
                assert dropped['document_path'] == str(drop_document.resolve()), dropped
                (output/'drop.json').write_text(json.dumps(dropped, indent=2)+'\n')
                menus = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'menus.png'), '--test-menu'],
                    cwd=ROOT, env={**env, 'MDF_NATIVE_TEST_OPEN': str(opened_document.resolve())}, capture_output=True, text=True, timeout=35)
                assert menus.returncode == 0, menus.stderr
                menu_result = json.loads(menus.stdout)
                assert menu_result['menu_test'] == 6 and menu_result['document_revision'] == 3, menu_result
                assert menu_result['document_path'] == str(opened_document.resolve()), menu_result
                assert menu_result['preferences']['theme'] == 'paper' and menu_result['ui']['points'] == 14, menu_result
                (output/'menus.json').write_text(json.dumps(menu_result, indent=2)+'\n')
                preferences_home = work/'preferences-home'
                preferences_home.mkdir()
                preferences_env = {**env, 'HOME': str(preferences_home)}
                saved = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'preferences.png'), '--test-preferences'],
                    cwd=ROOT, env=preferences_env, capture_output=True, text=True, timeout=35)
                assert saved.returncode == 0, saved.stderr
                saved_values = json.loads((preferences_home/'.config/mdf/settings.json').read_text())
                assert saved_values['save_settings_across_sessions'] and saved_values['font_size'] == 18
                assert saved_values['theme'] == 'paper' and not saved_values['line_wrap']
                restored = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'preferences-restored.png'), '--test-load-preferences'],
                    cwd=ROOT, env=preferences_env, capture_output=True, text=True, timeout=35)
                assert restored.returncode == 0, restored.stderr
                restored_values = json.loads(restored.stdout)
                expected_preferences = {**saved_values, 'line_wrap': True}
                assert restored_values['preferences'] == expected_preferences, (restored_values, saved_values)
                assert restored_values['ui']['points'] == 18 and restored_values['ui']['wrap'], restored_values
                (output/'preferences.json').write_text(json.dumps(restored_values, indent=2)+'\n')
                watched_document = work/'watched.md'
                watched_document.write_text('# Original watched file\n\nBefore the edit.\n')
                watcher = subprocess.Popen([str(binary), str(watched_document), str(output/'watch.png'), '--test-watch'],
                    cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    assert select.select([watcher.stdout], [], [], 10)[0], 'No initial frame from watcher'
                    assert watcher.stdout.readline() == 'ready\n'
                    watched_document.write_text('# Updated watched file\n\nAfter the external edit.\n')
                    watched_output, watched_error = watcher.communicate(timeout=15)
                    assert watcher.returncode == 0, watched_error
                    watched = json.loads(watched_output)
                    assert watched['document_revision'] >= 2 and watched['automatic_reloads'] >= 1, watched
                    (output/'watch.json').write_text(json.dumps(watched, indent=2)+'\n')
                finally:
                    if watcher.poll() is None:
                        watcher.kill()
                        watcher.communicate()
                missing_document = subprocess.run([str(binary), str(work/'missing.md'), str(output/'missing.png'), '--ui'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert missing_document.returncode == 0, missing_document.stderr
                missing_result = json.loads(missing_document.stdout)
                assert missing_result['document_revision'] == 0 and missing_result['status'] == 'FileNotFound', missing_result
                for mode, name in [('--show-menu', 'menu'), ('--show-dialog', 'dialog'),('--show-dialog-dark','dialog-dark'),('--show-dialog-small','dialog-small')]:
                    visible = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/(name+'.png')), mode],
                        cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                    assert visible.returncode == 0, visible.stderr
                    dialog=json.loads(visible.stdout)
                    if name=='dialog-small':assert (dialog['width'],dialog['height'])==(480,240),dialog
                    if name=='dialog-dark':assert dialog['ui']['dark'],dialog
                helper_dir=work/'helpers'; helper_dir.mkdir()
                helper=helper_dir/'xdg-open'
                helper.write_text('#!/bin/sh\nprintf \'%s\' "$1" > "$MDF_NATIVE_TEST_LINK_LOG"\n')
                helper.chmod(0o755)
                link_log=work/'link-argument'
                injection=work/'shell-injected'
                web_url='https://example.invalid/\'";$(touch${IFS}'+str(injection)+')'
                link_target=work/'next page.md'
                link_target.write_text('# Next page\n\n'+'A paragraph before the target.\n\n'*60+'<a id="section-target"></a>\n## Descriptive section\n\nTarget reached.\n')
                link_document=work/'links.md'
                link_document.write_text('# Links\n\n[System handler](<'+web_url+'>)\n\n[Local target](<next%20page.md#section%2Dtarget>)\n')
                linked=subprocess.run([str(binary),str(link_document),str(output/'links.png'),'--test-links'],cwd=ROOT,
                    env={**env,'PATH':str(helper_dir)+os.pathsep+os.environ['PATH'],'MDF_NATIVE_TEST_LINK_LOG':str(link_log)},
                    capture_output=True,text=True,timeout=35)
                assert linked.returncode==0,linked.stderr
                link_result=json.loads(linked.stdout)
                assert link_result['links']=={'stage':3,'external':1,'children':0},link_result
                assert link_result['document_path']==str(link_target) and link_result['scroll']>0,link_result
                assert link_log.read_text()==web_url and not injection.exists(), 'URL was interpreted by a shell'
                (output/'links.json').write_text(json.dumps(link_result,indent=2)+'\n')
                raster_document = work/'raster.md'
                raster_document.write_text('# Local raster images\n\n![Shapes]('+str(ROOT/'assets/sample-shapes.png')+')\n\n![Earthrise]('+str(ROOT/'assets/sample-earthrise.jpg')+')\n')
                svg = work/'only.svg'
                svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120"><rect width="240" height="120" fill="#3276b0"/><text x="14" y="65" fill="white" font-size="22">Native SVG pixels</text></svg>')
                svg_document = work/'svg.md'
                svg_document.write_text('# SVG only\n\n![Vector image]('+str(svg)+')\n')
                unsupported = work/'unsupported.md'
                unsupported.write_text('# Unsupported diagram\n\n```mermaid\njourney\n  title Source stays readable\n```\n')
                legacy = work/'legacy-fixtures'
                subprocess.run([sys.executable, str(ROOT/'tests/image-fixtures.py'), str(legacy)], check=True, capture_output=True)
                legacy_document = work/'legacy.md'
                legacy_document.write_text('# GIF and BMP\n\n![GIF first frame]('+str(legacy/'gif-0-1-1-1.gif')+')\n\n![Top-down BMP]('+str(legacy/'bmp-24-1.bmp')+')\n')
                asset_rows = []
                cases = [
                    ('small-ready', ROOT/'assets/samples/SAMPLE-SMALL.md', 0, 0, 0, False, False),
                    ('raster-ready', raster_document, 2, 0, 0, False, False),
                    ('svg-ready', svg_document, 0, 1, 0, True, False),
                    ('mermaid-ready', ROOT/'assets/samples/SAMPLE.md', None, 0, 1, True, True),
                    ('unsupported-ready', unsupported, 0, 0, 0, False, True),
                    ('legacy-ready', legacy_document, 2, 0, 0, False, False),
                    ('mermaid-theme', ROOT/'assets/samples/SAMPLE.md', None, 0, 1, True, True),
                ]
                for name, document, raster, vectors, mermaid, svg_loaded, mermaid_loaded in cases:
                    ready_env = {**env}
                    if name.startswith('mermaid-'):
                        ready_env['MDF_NATIVE_TEST_ANCHOR'] = 'mermaid-diagram'
                    ready = subprocess.run([str(binary), str(document), str(output/(name+'.png')), '--ready-theme' if name == 'mermaid-theme' else '--ready'],
                        cwd=ROOT, env=ready_env, capture_output=True, text=True, timeout=35)
                    assert ready.returncode == 0, (name, ready.stderr)
                    rendered = json.loads(ready.stdout)
                    assets = rendered['assets']
                    assert assets['finished'] and assets['started_ms'] >= rendered['flush_ms'], rendered
                    assert assets['counts']['svg'] == vectors and assets['counts']['mermaid'] == mermaid, rendered
                    if raster is not None:
                        assert assets['counts']['raster'] == raster, rendered
                    else:
                        assert assets['counts']['raster'] == 5, rendered
                    assert assets['svg_loaded'] == svg_loaded and assets['mermaid_loaded'] == mermaid_loaded, rendered
                    if name == 'small-ready':
                        assert not assets['worker_started'] and assets['count'] == 0 and rendered['paints'] == 1, rendered
                    if name == 'unsupported-ready':
                        assert assets['counts']['failures'] == 1, rendered
                    if name == 'mermaid-theme':
                        assert rendered['ui']['dark'] and assets['threads_started'] == 2 and rendered['paints'] >= 4, rendered
                    rendered['case'] = name
                    asset_rows.append(rendered)
                (output/'assets.json').write_text(json.dumps(asset_rows, indent=2)+'\n')
                inline = work/'inline.md'
                inline.write_text('# Inline code\n\nRegular **bold** text and `inline code` only.\n')
                code = work/'code.md'
                code.write_text('# Deferred monospace\n\nRegular **bold** text.\n\n```zig\nconst narrow = "iiii";\nconst wide = "WWWW";\n```\n')
                unicode = work/'unicode.md'
                unicode.write_text('# Привет κόσμε\n\nПривет **κόσμε** *Привет* ***κόσμε***.\n')
                mixed = work/'mixed.md'
                mixed.write_text(unicode.read_text()+'\n```text\nПривет κόσμε\n```\n')
                unicode_name = work/'Привет.md'
                unicode_name.write_text('# Latin document\n\nThe filename also needs glyph coverage.\n')
                glyph_svg = work/'glyphs.svg'
                glyph_svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="300" height="100"><text x="10" y="55" font-size="24">Привет κόσμε</text></svg>')
                glyph_diagrams = work/'glyph-diagrams.md'
                diagram_text = '# Diagram labels\n\n![Labels]('+str(glyph_svg)+')\n\n```mermaid\nflowchart LR\n  A[Привет] --> B[κόσμε]\n```\n'
                diagram_text += '\nLatin text below the diagrams.\n'*60
                glyph_diagrams.write_text(diagram_text+'\nПривет κόσμε\n')
                svg_glyphs = work/'svg-glyphs.svg'
                svg_glyphs.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="300" height="100"><metadata>Ignored 中文 metadata</metadata><text x="10" y="55" font-size="24">&#x41f;ривет <tspan>κόσμε</tspan></text></svg>')
                svg_glyph_document = work/'svg-glyphs.md'
                svg_glyph_document.write_text('# SVG label coverage\n\n![Labels]('+str(svg_glyphs)+')\n')
                svg_metadata = work/'svg-metadata.svg'
                svg_metadata.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="300" height="100"><metadata>Ignored 中文 metadata</metadata><text x="10" y="55" font-size="24">Latin label</text></svg>')
                svg_metadata_document = work/'svg-metadata.md'
                svg_metadata_document.write_text('# SVG metadata\n\n![Labels]('+str(svg_metadata)+')\n')
                without_text = work/'without-text'
                subprocess.run(['objcopy', '--remove-section=.mdf_text', str(binary), str(without_text)], check=True)
                degraded = subprocess.run([str(without_text), str(glyph_diagrams), str(output/'glyph-baseline-ready.png'), '--ready'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert degraded.returncode == 0, degraded.stderr
                degraded_result = json.loads(degraded.stdout)
                assert degraded_result['fonts']['sans_requested'] and not degraded_result['fonts']['sans_ready'], degraded_result
                assert 'missing' in degraded_result['fonts']['error_message'].lower(), degraded_result
                font_rows = []
                for name, document, mono, sans in [
                    ('inline', inline, False, False), ('code', code, True, False),
                    ('unicode', unicode, False, True), ('mixed-fonts', mixed, True, True),
                    ('unicode-name', unicode_name, False, True),
                    ('svg-glyphs', svg_glyph_document, False, True),
                    ('svg-metadata', svg_metadata_document, False, False),
                    ('glyph-diagrams', glyph_diagrams, False, True),
                    ('extended', ROOT/'assets/samples/SAMPLE-EXTENDED.md', False, True),
                ]:
                    first_capture = output/(name+'-first.png')
                    first = subprocess.run([str(binary), str(document), str(first_capture)],
                        cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                    assert first.returncode == 0, (name, first.stderr)
                    first_result = json.loads(first.stdout)
                    assert not first_result['fonts']['first_viewport_mono'] and not first_result['fonts']['first_viewport_fallback'], first_result
                    ready_capture = output/(name+'-ready.png')
                    ready = subprocess.run([str(binary), str(document), str(ready_capture), '--ready'],
                        cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                    assert ready.returncode == 0, (name, ready.stderr)
                    rendered = json.loads(ready.stdout)
                    fonts = rendered['fonts']
                    assert fonts['finished'] and not fonts['error_message'], rendered
                    assert fonts['mono_requested'] == mono and fonts['sans_requested'] == sans, rendered
                    assert fonts['mono_ready'] == mono and fonts['sans_ready'] == sans, rendered
                    assert fonts['module_loaded'] == (mono or sans), rendered
                    if mono or sans:
                        assert fonts['started_ms'] >= rendered['flush_ms'] and rendered['paints'] >= 2, rendered
                    else:
                        if not rendered['assets']['worker_started']:
                            assert rendered['paints'] == 1 and first_capture.read_bytes() == ready_capture.read_bytes(), rendered
                    if mono:
                        widths = fonts['code_widths']
                        assert widths['narrow'] > 0 and abs(widths['wide']-widths['narrow']) < .1, rendered
                    if sans:
                        assert fonts['requested_characters'] > 0 and fonts['sans_family'], rendered
                        if name != 'extended':
                            assert fonts['unresolved'] == 0, rendered
                    if name in ('code', 'unicode', 'mixed-fonts'):
                        assert first_capture.read_bytes() != ready_capture.read_bytes(), rendered
                    if name in ('glyph-diagrams', 'svg-glyphs'):
                        assets = rendered['assets']
                        assert assets['counts'] == {'raster': 0, 'svg': 1, 'mermaid': int(name == 'glyph-diagrams'), 'failures': 0}, rendered
                        assert assets['font_version'] == fonts['sans_version'] > 0, rendered
                        if name == 'svg-glyphs':
                            assert fonts['requested_characters'] == 11, rendered
                    if name in ('svg-glyphs', 'svg-metadata'):
                        assert ink_in_region(ready_capture, (100, 110, 450, 190)) > 100, 'SVG label pixels are blank'
                    if name == 'glyph-diagrams':
                        # The only visible difference is the diagram font:
                        # the glyph-triggering body paragraph is below view.
                        assert ready_capture.read_bytes() != (output/'glyph-baseline-ready.png').read_bytes(), 'Diagram fallback left the same missing-glyph pixels'
                    rendered['case'] = name
                    font_rows.append(rendered)
                (output/'fonts.json').write_text(json.dumps(font_rows, indent=2)+'\n')
                map_rows = []
                for name, document in [('small', ROOT/'assets/samples/SAMPLE-SMALL.md'), ('sample', ROOT/'assets/samples/SAMPLE.md'), ('huge', ROOT/'assets/samples/SAMPLE-HUGE.md'), ('extended',ROOT/'assets/samples/SAMPLE-EXTENDED.md')]:
                    capture = output/('minimap-'+name+'.png')
                    run = subprocess.run([str(binary), str(document), str(capture), '--ready-ui'],
                        cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                    assert run.returncode == 0, (name, run.stderr)
                    rendered = json.loads(run.stdout)
                    mini = rendered['minimap']
                    assert mini['finished'] and not mini['error_message'] and mini['jobs'] >= 1, rendered
                    assert not mini['first_viewport'] and mini['started_ms'] >= rendered['flush_ms'], rendered
                    assert 0 < mini['lines'] <= 2*(rendered['height']-138), rendered
                    if name == 'small':
                        assert not rendered['fonts']['module_loaded'], rendered
                        assert capture.read_bytes() != (output/'full-ui.png').read_bytes(), 'Minimap never gained text pixels'
                        assert png_region(capture,(0,0,916,780)) == png_region(output/'full-ui.png',(0,0,916,780)), 'Minimap painted outside its pane'
                    if name == 'extended':
                        assert mini['font_version'] == rendered['fonts']['sans_version'] > 0, rendered
                    rendered['case'] = name; map_rows.append(rendered)
                (output/'minimap.json').write_text(json.dumps(map_rows, indent=2)+'\n')
                missing_map = subprocess.run([str(without_text),str(ROOT/'assets/samples/SAMPLE-EXTENDED.md'),str(output/'minimap-extended-missing.png'),'--ready-ui'],
                    cwd=ROOT,env=env,capture_output=True,text=True,timeout=35)
                assert missing_map.returncode == 0, missing_map.stderr
                assert png_region(output/'minimap-extended.png',(916,94,1040,736)) != png_region(output/'minimap-extended-missing.png',(916,94,1040,736)), 'Minimap fallback kept the same missing-glyph pixels'
                assert len({r['minimap']['thumb_height'] for r in map_rows}) == 1, map_rows
                hidden_map = subprocess.run([str(binary), str(ROOT/'assets/samples/SAMPLE-SMALL.md'), str(output/'minimap-hidden.png'), '--ready-ui-no-preview'],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert hidden_map.returncode == 0, hidden_map.stderr
                hidden_result = json.loads(hidden_map.stdout)
                assert not hidden_result['ui']['preview'] and hidden_result['minimap']['jobs'] == 0, hidden_result
                assert hidden_result['minimap']['started_ms'] == 0 and hidden_result['body']['width'] == 800, hidden_result
                for name, document in [('small',ROOT/'assets/samples/SAMPLE-SMALL.md'),('huge',ROOT/'assets/samples/SAMPLE-HUGE.md')]:
                    drag = subprocess.run([str(binary),str(document),str(output/('minimap-drag-'+name+'.png')),'--test-minimap'],
                        cwd=ROOT,env=env,capture_output=True,text=True,timeout=35)
                    assert drag.returncode == 0, (name,drag.stderr)
                    dragged=json.loads(drag.stdout)
                    assert dragged['minimap']['dragged'] and dragged['scroll'] > 0, dragged
                    assert dragged['minimap']['jobs'] == dragged['minimap']['drag_jobs'], 'Dragging regenerated the text atlas'
                packed = application
                assert packed.is_file(), 'Missing native bootstrap application; build with make native'
                interactive_home=work/'interactive-home';interactive_home.mkdir()
                for initial in ([],[str(ROOT/'assets/samples/SAMPLE-SMALL.md')]):
                    opened=subprocess.Popen([str(packed),*initial],cwd=ROOT,env={**env,'HOME':str(interactive_home)},
                        stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                    try:
                        drop_trigger.write_text(str(opened.pid)+' close')
                        ordinary_output,ordinary_error=opened.communicate(timeout=15)
                    finally:
                        drop_trigger.unlink(missing_ok=True)
                        if opened.poll() is None:opened.kill();opened.communicate()
                    assert opened.returncode==0 and ordinary_output=='',(initial,ordinary_output,ordinary_error)
                one_file=work/'mdf-one-file';shutil.copy2(packed,one_file)
                independent=subprocess.run([str(one_file),'--benchmark',str(ROOT/'assets/samples/SAMPLE.md')],cwd=work,
                    env=env,capture_output=True,text=True,timeout=35)
                assert independent.returncode==0,independent.stderr
                one_result=json.loads(independent.stdout)
                assert one_result['assets']['counts']['raster']>0 and one_result['assets']['mermaid_loaded'] and one_result['fonts']['mono_ready'],one_result
                assert not one_file.with_name(one_file.name+'.debug').exists() and not (work/'lib').exists()
                boot_rows = []
                for document in ('SAMPLE-SMALL.md', 'SAMPLE.md', 'SAMPLE-HUGE.md', 'SAMPLE-EXTENDED.md'):
                    capture = output/(Path(document).stem+'-bootstrap.png')
                    boot_started=time.monotonic_ns()
                    boot = subprocess.run([str(packed), '--benchmark', str(ROOT/'assets/samples'/document), '--capture', str(capture)],
                        cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                    boot_finished=time.monotonic_ns()
                    assert boot.returncode == 0, (document, boot.stderr)
                    (output/(Path(document).stem+'-bootstrap-raw.json')).write_text(boot.stdout+'\n')
                    result = json.loads(boot.stdout)
                    assert result['bootstrapped'] and result['document_revision'] == 1, result
                    events = result['events']
                    assert result['profile_version']==1 and result['mode']=='ReleaseFast',result
                    assert result['compiler']==(ROOT/'.zig-version').read_text().strip(),result
                    assert result['keyboard_ready'] and result['metrics']['input_ready'],result
                    assert result['file_browser']['jobs']==0 and not result['file_browser']['loading'],result
                    assert not result['dropped_events'] and not result['dropped_wait_details'],result
                    assert result['metrics']['first_document_ms']==result['flush_ms'],result
                    assert result['metrics']['first_frame_ms']==result['ready_ms']>=result['frame_callback_ms'],result
                    assert any(event['name']=='Paint and submit native window' for event in events),events
                    assert any(event['track']=='minimap' and event['kind']=='work' for event in events),events
                    waits=[event for event in events if event['kind']=='wait' and event['name'].startswith(('Wait for native','Wait for Wayland'))]
                    assert waits and all('wait' in event and event['wait']['watched_fds'] for event in waits),waits
                    for name,metric in [('First Markdown viewport','first_document_ms'),('Native fully ready','first_frame_ms')]:
                        signal=next(event for event in events if event['name']==name)
                        assert signal['start_ns']==round(result['metrics'][metric]*1e6),(signal,result['metrics'])
                    assert sum(event['name'] == 'Read Markdown file' for event in events) == 1, events
                    assert sum(event['name'] == 'Accept document' for event in events) == 1, events
                    assert any(event['name'] == 'UI engine ready' for event in events), events
                    assert 0 < result['commit_ms'] <= result['flush_ms'] <= result['frame_callback_ms'], result
                    assert not result['fonts']['first_viewport_mono'] and not result['fonts']['first_viewport_fallback'], result
                    assert result['assets']['started_ms'] >= result['flush_ms'], result
                    assert result['minimap']['finished'] and result['minimap']['started_ms'] >= result['flush_ms'], result
                    if document == 'SAMPLE-SMALL.md':
                        assert not result['fonts']['module_loaded'] and not result['assets']['worker_started'], result
                        assert png_region(capture,(0,0,1040,780)) == png_region(output/'minimap-small.png',(0,0,1040,780)), 'Bootstrap changed the small document pixels'
                    if document == 'SAMPLE-EXTENDED.md':
                        assert not result['fonts']['mono_requested'] and result['fonts']['sans_ready'] and not result['fonts']['unresolved'], result
                    result['document'] = document
                    analyzed=profile.analyze_run(profile.include_process_launch(result,boot_started,boot_finished))
                    model=analyzed['call_graph'];nodes={node['id']:node for node in model['nodes']}
                    for endpoint,metric in [('viewport','first_document_ms'),('ready','first_frame_ms')]:
                        path=model['paths'][endpoint]
                        assert sum(nodes[key]['duration_ns'] for key in path['node_ids'])==path['total_ns']==round(analyzed['metrics'][metric]*1e6),path
                        if endpoint=='viewport':
                            assert not any(nodes[key]['track'] in ('fonts','fallback','images','minimap') for key in path['node_ids']),path
                    boot_rows.append(analyzed)
                (output/'bootstrap.json').write_text(json.dumps(boot_rows,indent=2)+'\n')
                anchored = subprocess.run([str(packed), '--benchmark', str(ROOT/'assets/samples/SAMPLE.md'), '--capture', str(output/'bootstrap-anchor.png'),
                    '--capture-anchor', 'layout-stress', '--capture-reader'], cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
                assert anchored.returncode == 0, anchored.stderr
                anchored_result = json.loads(anchored.stdout)
                assert anchored_result['scroll'] > 0 and not anchored_result['ui']['toc'] and not anchored_result['ui']['preview'], anchored_result
                assert anchored_result['minimap']['jobs'] == 0, anchored_result
                for document in ('SAMPLE-SMALL.md','SAMPLE.md','SAMPLE-HUGE.md'):
                    name=Path(document).stem
                    capture=output/(name+'-scroll-startup.png')
                    started=time.monotonic_ns()
                    scrolling=subprocess.run([str(packed),'--profile-scroll',str(ROOT/'assets/samples'/document),'--capture',str(capture)],
                        cwd=ROOT,env=env,capture_output=True,text=True,timeout=35)
                    finished=time.monotonic_ns()
                    assert scrolling.returncode==0,(document,scrolling.stderr)
                    measured=json.loads(scrolling.stdout)
                    assert measured['scroll_frames']==80 and len(measured['scroll_draw_ms'])==80 and all(value>0 for value in measured['scroll_draw_ms']),measured
                    assert measured['scroll_restored'] and measured['paints']==measured['startup_paints']+81,measured
                    assert measured['scroll']==0,measured
                    assert measured['metrics']['total_frames']==measured['startup_paints'] and measured['metrics']['document_frames']==measured['startup_paints'],measured
                    assert not measured['dropped_events'] and not measured['dropped_wait_details'],measured
                    boundary=round(measured['metrics']['first_frame_ms']*1e6)
                    assert all(event['start_ns']+event['duration_ns']<=boundary for event in measured['events']),measured['events']
                    assert png_region(capture,(0,0,1040,780))==png_region(output/(name+'-bootstrap.png'),(0,0,1040,780)), 'Scrolling changed the captured startup viewport'
                    analyzed=profile.analyze_run(profile.include_process_launch(measured,started,finished))
                    model=analyzed['call_graph'];nodes={node['id']:node for node in model['nodes']}
                    for endpoint in ('viewport','ready'):
                        path=model['paths'][endpoint]
                        assert sum(nodes[key]['duration_ns'] for key in path['node_ids'])==path['total_ns'],path
                    (output/(name+'-scroll.json')).write_text(json.dumps(analyzed,indent=2)+'\n')
                missing = subprocess.run([str(packed), '--benchmark', str(work/'does-not-exist.md')],
                    cwd=ROOT,env=env,capture_output=True,text=True,timeout=10)
                assert missing.returncode != 0 and 'DocumentLoadFailed' in missing.stderr, missing.stderr
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
    print('PASS: native Wayland presentation, input, clipboard, menus, file opening, preferences, auto-reload and graphics-free library closure')


if __name__ == '__main__':
    main()
