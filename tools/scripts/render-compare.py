#!/usr/bin/env python3
"""Capture real MDF/Typora section pairs for a visual rendering review.

Uses a private Weston desktop and disposable Typora profiles/documents.
No remote-debugging flags, application patching, pixel-equality scoring, or
changes to the user's Typora settings. This is a correctness aid, not a speed test.
"""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
CASES = [
    ('top', '', ''), ('headings', '## Headings', 'headings'),
    ('styles', '## Text styles', 'text-styles'),
    ('paragraphs', '## Paragraphs and line breaks', 'paragraphs-and-line-breaks'),
    ('lists', '## Lists', 'lists'),
    ('list-paragraphs', '### List with paragraphs and a code block', 'list-with-paragraphs-and-a-code-block'),
    ('quotes', '## Block quotes', 'block-quotes'), ('links', '## Links', 'links'),
    ('images', '## Images', 'images'), ('code', '## Code', 'code'),
    ('json', '### JSON', 'json'), ('shell', '### Shell', 'shell'),
    ('fences', '### Tilde and empty fences', 'tilde-and-empty-fences'),
    ('long-code', '### A long code line', 'a-long-code-line'),
    ('rules', '## Horizontal rules', 'horizontal-rules'),
    ('tables', '## Tables', 'tables'),
    ('long-table', '### Empty cells and long content', 'empty-cells-and-long-content'),
    ('wide-table', '### Wide table with long cells', 'wide-table-with-long-cells'),
    ('release-matrix', '### Sixteen-column release matrix', 'sixteen-column-release-matrix'),
    ('many-columns', '### Twenty-four-column measurements', 'twenty-four-column-measurements'),
    ('alerts', '## GitHub alerts', 'github-alerts'),
    ('details', '## Collapsible sections', 'collapsible-sections'),
    ('footnotes', '### Footnotes', 'footnotes'), ('html', '### Raw HTML', 'raw-html'),
    ('math', '### Mathematics', 'mathematics'), ('mermaid', '### Mermaid diagram', 'mermaid-diagram'),
    ('unicode', '## Unicode and symbols', 'unicode-and-symbols'),
    ('stress', '## Layout stress', 'layout-stress'), ('end', '## End of document', 'end-of-document')]
CASE_DOCUMENTS = {'unicode': 'SAMPLE-EXTENDED.md'}


def stop(process):
    if process is None or process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def healthy_png(path):
    from PIL import Image, ImageStat
    with Image.open(path) as image:
        if image.width < 400 or image.height < 240:
            raise RuntimeError(f'Too-small capture: {path}')
        body = image.crop((15, 35, image.width-15, image.height-35)).convert('L')
        # A menu/status bar or mouse cursor can give a blank editor nonzero
        # variance. Require substantial ink in the actual document area.
        histogram = body.histogram()
        ink = sum(histogram[:200]) / (body.width * body.height)
        if ImageStat.Stat(body).stddev[0] < 5 or ink < .005:
            raise RuntimeError(f'Blank or unfinished capture: {path}')
        return {'width': image.width, 'height': image.height,
                'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def find_focused(path):
    """The disposable default Typora theme outlines its focused Find field blue.

    Require a long horizontal border; scattered blue source text and the
    blinking caret do not satisfy the focus check.
    Fail closed if a different UI/theme no longer supplies this visual signal.
    """
    from PIL import Image
    with Image.open(path) as image:
        band=image.convert('RGB').crop((80,30,image.width-130,70))
        pixels=band.tobytes()
        stride=band.width*3
        for row in range(band.height):
            run=0
            line=pixels[row*stride:(row+1)*stride]
            for r,g,b in zip(line[::3],line[1::3],line[2::3]):
                run=run+1 if b>130 and b>r+35 and g>r+10 else 0
                if run>image.width*.4:
                    return True
        return False


class Desktop:
    def __init__(self, directory, module, width):
        self.directory, self.module, self.width = directory, module, width
        self.process = self.typora = None
        self.instance = None
        self.input = None
        self.logs = []
        self.runtime = None

    def launch(self, args, environment, name, **kwargs):
        log = (self.directory/name).open('w')
        self.logs.append(log)
        return subprocess.Popen(args, env=environment, stdout=log, stderr=log,
                                start_new_session=True, **kwargs)

    def __enter__(self):
        runtime = self.runtime = Path(tempfile.mkdtemp(prefix='mdf-render-'))
        fifo = runtime/'input'
        os.mkfifo(fifo, 0o600)
        self.environment = {**os.environ, 'XDG_RUNTIME_DIR': str(runtime),
                            'WAYLAND_DISPLAY': 'mdf-render', 'MDF_RENDER_INPUT': str(fifo)}
        self.environment.pop('WAYLAND_SOCKET', None)
        self.process = self.launch(['weston', '--backend=headless', '--renderer=gl', '--shell=kiosk-shell.so',
                                    '--modules='+str(self.module), '--no-config', '--socket=mdf-render', '--idle-time=0',
                                    '--width='+str(self.width), '--height=780', '--log='+str(self.directory/'weston.log')],
                                   self.environment, 'weston-output.log')
        for _ in range(200):
            if (runtime/'mdf-render').is_socket():
                self.input = os.open(fifo, os.O_WRONLY)
                return self
            if self.process.poll() is not None:
                self.__exit__()
                raise RuntimeError('Private Weston failed; see '+str(self.directory/'weston.log'))
            time.sleep(.05)
        self.__exit__()
        raise RuntimeError('Private Wayland socket did not appear')

    def key(self, code, flags=0):
        os.write(self.input, f'key {code} {flags}\n'.encode())

    def type_query(self, value):
        codes = {letter: (start+i, 0) for letters,start in [('qwertyuiop',16),('asdfghjkl',30),('zxcvbnm',44)]
                 for i,letter in enumerate(letters)}
        codes.update({letter:(2+i,0) for i,letter in enumerate('1234567890')})
        codes.update({' ':(57,0), '#':(4,2), '-':(12,0), '.':(52,0), ',':(51,0), '/':(53,0)})
        for char in value.lower():
            self.key(*codes[char])
            time.sleep(.025)

    def wait_find(self, focused):
        deadline=time.monotonic()+12
        while time.monotonic()<deadline:
            state=self.directory/'find-state.png'
            self.screenshot(state,validate=False)
            if find_focused(state)==focused:
                return
            time.sleep(.2)
        raise RuntimeError(f'Typora Find focus did not become {focused}; stopping the capture')

    def section(self, raw_heading):
        if not raw_heading:
            self.key(102,1)  # Ctrl+Home, rendered mode
            time.sleep(.5)
            return
        # Source-mode Find uniquely matches literal Markdown headings rather
        # than identically named links in the table of contents. Then return
        # to the actual rendered document and jump to the selection.
        self.key(53,1); time.sleep(.8)
        self.key(102,1); time.sleep(.15)
        self.key(33,1)
        self.wait_find(True)
        self.key(30,1); time.sleep(.1)
        self.type_query(raw_heading); time.sleep(.4)
        self.screenshot(self.directory/'query-state.png',validate=False)
        self.key(1)
        self.wait_find(False)
        self.key(53,1); time.sleep(.8)
        self.key(36,1); time.sleep(.8)

    def screenshot(self, destination, validate=True):
        staging = self.directory/'shots'
        staging.mkdir(exist_ok=True)
        result = subprocess.run(['weston-screenshooter'], cwd=staging, env=self.environment,
                                capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise RuntimeError('Weston capture failed: '+result.stderr)
        files = list(staging.glob('wayland-screenshot-*.png'))
        if len(files) != 1:
            raise RuntimeError('Expected exactly one compositor screenshot')
        files[0].replace(destination)
        return healthy_png(destination) if validate else None

    def open_typora(self, document):
        # Flatpak prints an instance ID to an owned pipe. Cleanup kills this
        # exact instance, never the user's existing Typora windows.
        read_fd, write_fd = os.pipe()
        os.set_blocking(read_fd, False)
        display = str(self.runtime/'mdf-render')
        environment = {**os.environ, 'WAYLAND_DISPLAY': display}
        self.typora = self.launch(['flatpak','run','--instance-id-fd='+str(write_fd),'--nosocket=x11',
                                   '--env=WAYLAND_DISPLAY='+display,'--filesystem='+str(self.runtime)+':ro','io.typora.Typora',
                                   '--user-data-dir='+str(self.directory/'typora-profile'),
                                   '--disable-renderer-backgrounding','--disable-features=Vulkan','--ozone-platform=wayland',str(document)],
                                  environment,'typora.log',pass_fds=(write_fd,))
        os.close(write_fd)
        raw = b''
        try:
            for _ in range(400):
                try:
                    raw += os.read(read_fd,4096)
                except BlockingIOError:
                    pass
                candidate = raw.strip(b'\0\r\n ')
                if candidate.isdigit():
                    self.instance = candidate.decode()
                    break
                if self.typora.poll() is not None:
                    raise RuntimeError('Typora exited; see '+str(self.directory/'typora.log'))
                time.sleep(.05)
        finally:
            os.close(read_fd)
        if not self.instance or not self.instance.isdigit():
            raise RuntimeError('Could not identify the owned Typora instance')
        initial = self.directory/'reference-ready.png'
        for _ in range(60):
            try:
                self.screenshot(initial)
                time.sleep(2)
                return
            except RuntimeError:
                time.sleep(.25)
        raise RuntimeError('Typora never produced a rendered frame')

    def close_typora(self):
        if self.instance:
            subprocess.run(['flatpak','kill',self.instance],capture_output=True,timeout=10)
            self.instance = None
        stop(self.typora)
        self.typora = None

    def __exit__(self, *_):
        self.close_typora()
        if self.input is not None:
            os.close(self.input)
            self.input = None
        stop(self.process)
        if self.runtime:
            shutil.rmtree(self.runtime,ignore_errors=True)
            self.runtime = None
        for log in self.logs:
            log.close()


def report(directory, records, document_hashes, complete=False):
    cards = []
    for record in records:
        title = record['title'] or 'Document start'
        cards.append('<article><h2>'+html.escape(title)+f" · {record['width']} px</h2><div class=pair>"+
                     ''.join('<figure><figcaption>'+label+'</figcaption><a href="'+html.escape(record[key])+'"><img loading=lazy src="'+html.escape(record[key])+'" alt="'+html.escape(label+' '+title)+'"></a></figure>'
                             for key,label in [('mdf','MDF · native renderer'),('typora','Typora · default theme')])+'</div></article>')
    content='''<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>MDF / Typora rendering comparison</title>
<style>body{font:15px system-ui;margin:28px auto;max-width:1500px;padding:0 20px;background:#151d29;color:#e4eaf1}p{line-height:1.5;max-width:1100px}h1{font-size:26px}h2{font-size:18px;margin:24px 0 10px}.pair{display:grid;grid-template-columns:1fr 1fr;gap:16px}figure{margin:0}figcaption{padding:8px;background:#263348}img{display:block;width:100%;height:auto;background:white}a{color:#90baff}article{border-top:1px solid #39475a;margin-top:28px}code{font-size:12px}@media(max-width:700px){.pair{grid-template-columns:1fr}}</style>
<h1>MDF / Typora · rendering comparison</h1>'''+f'<p>{len(records)} section pairs captured. Capture checks: '+('complete.' if complete else 'in progress.')+'</p>'+'''
<p>This test opens identical frozen Markdown bytes in both applications on private Wayland desktops at 1040 and 480 pixels wide. Regular cases use SAMPLE.md; script and symbol coverage uses SAMPLE-EXTENDED.md. MDF uses its production renderer with navigation hidden for the document capture. Typora uses a disposable profile and normal source-mode Find solely to navigate, returning to rendered mode before each capture. Its screenshot includes its menu and status bars.</p>
<p><strong>Visual review is required.</strong> Successful captures do not establish semantic equivalence. Inspect missing content, overlapping text, malformed tables, clipped ordinary paragraphs and failed local images. Font sizes, spacing, code styling, UI chrome and supported extensions may differ legitimately. Extended characters use installed system fallback fonts when available. The regular sample contains an intentionally missing image.</p>
<p>The applications are not required to match pixels. This is not a speed benchmark. Existing Typora preferences and source documents remain unchanged; only the owned reference instance is closed. A temporary reference profile may show an unregistered banner.</p>'''+''.join(f'<p>{html.escape(name)} SHA-256: <code>{digest}</code></p>' for name,digest in document_hashes.items())+''.join(cards)+'</html>'
    (directory/'report.html').write_text(content)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,default=ROOT/'build/bin/mdf')
    parser.add_argument('--output',type=Path,default=ROOT/'build/render-comparison')
    parser.add_argument('--case',action='append',choices=[c[0] for c in CASES])
    parser.add_argument('--latin-only',action='store_true',help='Review the regular sample without the extended-script fixture')
    parser.add_argument('--check',action='store_true')
    args=parser.parse_args()
    cases=[c for c in CASES if (not args.case or c[0] in args.case) and
           (not args.latin_only or c[0] not in CASE_DOCUMENTS)]
    if not cases:
        parser.error('No sections selected for the requested scope')
    groups={}
    for case in cases:
        groups.setdefault(CASE_DOCUMENTS.get(case[0],'SAMPLE.md'),[]).append(case)
    sources={name:(ROOT/'assets/samples'/name).read_bytes() for name in groups}
    hashes={name:hashlib.sha256(source).hexdigest() for name,source in sources.items()}
    for name,heading,_ in cases:
        if heading and sources[CASE_DOCUMENTS.get(name,'SAMPLE.md')].lower().count(heading.lower().encode())!=1:
            raise RuntimeError('Reference navigation requires a unique source heading: '+heading)
    if args.check:
        print('PASS:',len(cases),'unique sample sections and explicit capture anchors')
        return
    from PIL import Image
    for tool in ['weston','weston-screenshooter','flatpak','pkg-config','gcc']:
        if not shutil.which(tool):
            raise RuntimeError('Missing visual-comparison requirement: '+tool)
    subprocess.run(['flatpak','info','io.typora.Typora'],capture_output=True,check=True)
    directory=args.output.resolve()/('render-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ'))
    directory.mkdir(parents=True)
    module=directory/'render-seat.so'
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','libweston-15','wayland-server'],text=True).split()
    subprocess.run(['gcc','-shared','-fPIC','-Wno-attributes',str(ROOT/'tests/render-seat.c'),'-o',str(module),*flags],check=True)
    document=directory/'document'
    samples=document/'assets/samples'
    samples.mkdir(parents=True)
    for name,source in sources.items():
        sample=samples/name
        sample.write_bytes(source)
        sample.chmod(0o444)
    # Freeze the local image inputs as well as the Markdown and executable.
    # A concurrent asset edit must not change half of a comparison pair.
    assets=document/'assets'
    assets.mkdir(exist_ok=True)
    for original in (ROOT/'assets').glob('sample-*'):
        if original.is_file() and original.suffix in ('.jpg','.jpeg','.png'):
            shutil.copy2(original,assets/original.name)
    binary=directory/'mdf'
    shutil.copy2(args.binary.resolve(),binary)
    records=[]
    for width in [1040,480]:
        capture=directory/str(width)
        capture.mkdir()
        with Desktop(capture,module,width) as desktop:
            for source_name,sections in groups.items():
                desktop.open_typora(samples/source_name)
                for name,heading,_ in sections:
                    desktop.section(heading)
                    desktop.screenshot(capture/(name+'-typora.png'))
                    print(f'Typora {width}: {name} ({source_name})',flush=True)
                desktop.close_typora()
            for name,heading,anchor in cases:
                target=capture/(name+'-mdf.png')
                command=[str(binary),'--profile','--capture',str(target),'--capture-reader']
                if anchor:
                    command+=['--capture-anchor',anchor]
                source_name=CASE_DOCUMENTS.get(name,'SAMPLE.md')
                command.append(str(samples/source_name))
                proc=subprocess.run(command,env=desktop.environment,capture_output=True,text=True,timeout=45)
                (capture/(name+'-mdf.log')).write_text(proc.stderr)
                if proc.returncode:
                    raise RuntimeError('MDF capture failed: '+proc.stderr)
                json.loads(proc.stdout) # A real completed native profile, not a substitute HTML renderer.
                healthy_png(target)
                records.append({'title':heading.lstrip('# ').strip(),'document':source_name,'width':width,'mdf':str(target.relative_to(directory)),
                                'typora':str((capture/(name+'-typora.png')).relative_to(directory))})
                report(directory,records,hashes)
                print(f'MDF {width}: {name}',flush=True)
    assert all((samples/name).read_bytes()==source and (ROOT/'assets/samples'/name).read_bytes()==source for name,source in sources.items())
    report(directory,records,hashes,complete=True)
    print('Report:',directory/'report.html',flush=True)


if __name__=='__main__':
    main()
