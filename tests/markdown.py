#!/usr/bin/env python3
"""Offline CommonMark/GFM and MDF parser compatibility checks."""
from pathlib import Path
import json
import subprocess
import sys

root=Path(__file__).resolve().parents[1]
binary=Path(sys.argv[1]).resolve()
total=0
for name,mode,count in [('commonmark-spec-0.31.2.json',[],652),('gfm-extensions.json',['gfm'],24),('markdown-compatibility.json',[],90)]:
    cases=json.loads((root/'tests/fixtures'/name).read_text())
    assert len(cases)==count,(name,len(cases))
    failures=[]
    for number,case in enumerate(cases,1):
        run=subprocess.run([str(binary),*mode],input=case['markdown'],capture_output=True,text=True,timeout=10)
        if run.returncode or run.stdout!=case['html']:
            failures.append({'example':case.get('example',number),'section':case.get('section','compatibility'),
                'markdown':case['markdown'],'expected':case['html'],'actual':run.stdout,'error':run.stderr})
    if failures:
        for failure in failures[:8]:print(json.dumps(failure,ensure_ascii=False,indent=2),file=sys.stderr)
        raise SystemExit(f'{name}: {len(failures)}/{count} cases failed')
    print(f'PASS: {name}: {count}/{count}')
    total+=count
print(f'PASS: {total} Markdown specification and compatibility cases')
