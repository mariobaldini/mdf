#!/usr/bin/env python3
"""Check real GUI captures: readiness requires committed, socket-flushed pixels."""
import json
from pathlib import Path
import sys
import os

count=0
prepared=0
experimental=False
for path in Path(sys.argv[1]).glob('*.log'):
    try: run=json.loads(path.read_text())
    except (ValueError,UnicodeError): continue
    if not isinstance(run,dict) or 'metrics' not in run: continue
    m=run['metrics']
    assert 0 < m['first_document_commit_ms'] <= m['first_document_flush_ms'] <= m['first_document_ms'] <= m['first_frame_ms'],path
    assert m['input_ready'],path
    if os.environ.get('MDF_TEST_CURSOR_SHAPES'):
        assert m['cursor_backend']=='compositor-shape',path
        assert any(e['name']=='Compositor cursor shapes ready' for e in run['events']),path
        assert not any(e['name']=='Load Wayland cursor theme' for e in run['events']),path
    elif 'cursor_backend' in m:
        assert m['cursor_backend']=='theme',path
    if m.get('drawing_buffers')=='shared-until-busy':
        assert any(e['name']=='Create shared Cairo drawing surface' for e in run['events']),path
    for name in ('monospace_request_ms','fallback_request_ms'):
        if name in m: assert m[name] > m['first_document_ms'],(path,name)
    if m.get('diagram_module_loaded'):
        assert m['diagram_module_ready_ms'] > m['first_document_ms'],path
        for kind in ('svg', 'mermaid'):
            phases=[e for e in run['events'] if e['name']==f'Prepare bundled {"SVG" if kind=="svg" else "Mermaid"} module']
            assert len(phases)==int(m[kind+'_module_loaded']),path
            if phases:
                assert phases[0]['track']=='images' and phases[0]['start_ns']/1e6 >= m['first_document_ms'],path
    else:
        assert not any(e['name'] in ('Prepare bundled SVG module','Prepare bundled Mermaid module') for e in run['events']),path
    if run.get('keyboard_preparation')=='worker':
        for event in run['events']:
            if event['name']=='Load Wayland cursor theme':
                assert event['start_ns']/1e6 >= m['first_document_ms'],path
    count+=1
    prepared+=sum('before configure' in event['name'] for event in run['events'])
    experimental=experimental or run.get('frame_preparation')=='preconfigure'
assert count>=5,count
if os.environ.get('MDF_TEST_COMPOSITOR_PRELOAD') and experimental:
    assert prepared,'Delayed compositor did not exercise early-buffer preparation'
print(f'PASS: {count} real GUI profiles wait for committed/flushed Markdown before deferred work')
