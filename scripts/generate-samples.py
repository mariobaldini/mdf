#!/usr/bin/env python3
"""Rebuild the deterministic, synthetic long-document workload and its images.

Pillow and NumPy are needed only to regenerate committed test assets. This
does not copy SAMPLE.md or reuse image files between huge-document chapters.
The small sample's credited NASA JPEG is downloaded separately; no network
access is used here. Data and place names below are fictional test fixtures.
"""
import argparse
import hashlib
import math
from pathlib import Path
import random

ROOT = Path(__file__).resolve().parent.parent
NAMES = ['Alder', 'Birch', 'Cedar', 'Dune', 'Elm', 'Fir', 'Grove', 'Harbor', 'Iris', 'Juniper']
PLACES = ['Basin', 'Creek', 'Delta', 'Estuary', 'Forest', 'Gorge', 'Heath', 'Island', 'Marsh', 'Ridge']
TOPICS = ['Temperature monitoring', 'Rainfall collection', 'River level tracking', 'Wind observations',
          'Soil moisture sampling', 'Solar power management', 'Telemetry delivery', 'Clock synchronization',
          'Equipment maintenance', 'Data quality review']
SECTIONS = ['Site overview', 'Sensor placement', 'Acquisition schedule', 'Calibration procedure',
            'Power budget', 'Network behavior', 'Storage and retention', 'Quality checks',
            'Field maintenance', 'Incident response', 'Monthly review', 'Handover notes']
COLORS = ['#2979ad', '#d47236', '#3c927b', '#8a62a8', '#bd9951']


def image(path, index, kind=None):
    """Varied charts/diagrams and textured fields, not renamed/cropped copies."""
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont
    rng = random.Random(7421 + index)
    sizes = [(720, 400), (960, 540), (640, 480), (1200, 600), (800, 320),
             (1024, 768), (600, 600), (1440, 810), (840, 420), (480, 320)]
    width, height = sizes[index % len(sizes)]
    kind = kind if kind is not None else index % 10
    font = ImageFont.truetype(str(ROOT/'assets/fonts/open-sans/OpenSans-Regular.ttf'), max(13, width//48))
    title_font = ImageFont.truetype(str(ROOT/'assets/fonts/open-sans/OpenSans-Bold.ttf'), max(17, width//37))
    canvas = Image.new('RGB', (width, height), '#f6f8fa')
    draw = ImageDraw.Draw(canvas)
    title = f'Station {index:03d} / {TOPICS[index % 10]}'
    draw.text((24, 14), title, font=title_font, fill='#263545')
    left, top, right, bottom = 60, 65, width-30, height-45
    if path.suffix == '.jpg':
        # A different smooth spatial field with local texture for each station.
        # Explicitly synthetic: these are not presented as photographs.
        nrng = np.random.default_rng(8800 + index)
        y, x = np.mgrid[0:height, 0:width]
        field = (np.sin(x/(35+index%23) + index)*.22 + np.cos(y/(26+index%31))*.22 +
                 np.sin((x+y)/(63+index%19))*.15 + nrng.normal(0, .045, (height,width)))
        field = np.clip(field + .5, 0, 1)
        channels = [np.clip(45+field*180,0,255), np.clip(50+(1-abs(field-.5)*1.7)*170,0,255),
                    np.clip(195-field*145,0,255)]
        canvas = Image.fromarray(np.stack(channels,axis=-1).astype('uint8'))
        draw = ImageDraw.Draw(canvas)
        draw.rectangle((12,10,width-12,58),fill='#f6f8fa')
        draw.text((24,16), f'Simulated spatial survey {index:03d}',font=title_font,fill='#263545')
        for j in range(8):
            px,py=rng.randrange(40,width-40),rng.randrange(80,height-30)
            draw.ellipse((px-5,py-5,px+5,py+5),fill='white',outline='#24374a',width=2)
            draw.text((px+8,py-9),str(j+1),font=font,fill='#182c3c')
        if index % 4 == 0:
            canvas = canvas.convert('L')
        canvas.save(path, quality=82+index%8, progressive=bool(index%2), optimize=True)
        return
    if kind in (3, 7):
        # A flow diagram, with labels and transparency in some PNG fixtures.
        labels = ['Sensors', 'Validation', 'Queue', 'Archive']
        for j,label in enumerate(labels):
            x=left+j*(right-left)//4
            w=(right-left)//4-16
            y=height//2-35+(j%2)*18
            draw.rounded_rectangle((x,y,x+w,y+70),radius=8,fill=COLORS[(j+index)%5])
            draw.text((x+8,y+24),label,font=font,fill='white')
            if j<3:
                draw.line((x+w+3,y+35,x+w+14,y+35),fill='#526577',width=3)
                draw.polygon([(x+w+14,y+35),(x+w+8,y+30),(x+w+8,y+40)],fill='#526577')
        draw.text((left,height-42),f'Pipeline revision {index+1}; retry queue {index%7+2}',font=font,fill='#455969')
        if kind == 7:
            canvas = canvas.convert('RGBA')
            pixels = np.asarray(canvas).copy()
            pixels[:,:,3] = np.where(np.all(pixels[:,:,:3] == (246,248,250),axis=2),0,255)
            canvas=Image.fromarray(pixels)
    else:
        for j in range(5):
            y=top+j*(bottom-top)//4
            draw.line((left,y,right,y),fill='#d9e2ea')
            draw.text((8,y-8),str(100-j*25),font=font,fill='#516676')
        draw.line((left,top,left,bottom,right,bottom),fill='#738695',width=2)
        if kind in (1, 6):
            # Grouped bars / stacked distribution, with distinct values.
            for j in range(12):
                x=left+12+j*(right-left)//12
                value=rng.uniform(.12,.9)
                bar=max(6,(right-left)//18)
                y=bottom-int(value*(bottom-top))
                draw.rectangle((x,y,x+bar,bottom-1),fill=COLORS[(index+j)%5])
                if kind == 6:
                    draw.rectangle((x,y,x+bar,y+int((bottom-y)*.3)),fill=COLORS[(index+j+2)%5])
        elif kind == 4:
            for j in range(160):
                x=rng.uniform(left+4,right-4)
                value=.65*(x-left)/(right-left)+rng.gauss(0,.11)
                y=bottom-max(0,min(1,value))*(bottom-top)
                draw.ellipse((x-3,y-3,x+3,y+3),fill=COLORS[(j+index)%5])
        else:
            for series in range(3):
                points=[]
                for j in range(100):
                    x=left+(right-left)*j/99
                    value=.5+.2*math.sin(j/(8+series)+index)+series*.07+rng.uniform(-.045,.045)
                    points.append((x,bottom-value*(bottom-top)))
                draw.line(points,fill=COLORS[(index+series)%5],width=max(2,width//400))
        draw.text((left,bottom+12),f'Observation period / batch {index+1}',font=font,fill='#455969')
    if index % 5 == 1:
        canvas = canvas.convert('P',palette=Image.Palette.ADAPTIVE,colors=128)
    canvas.save(path,optimize=True)


def paragraph(rng, site, topic, section, number):
    value=rng.uniform(2,98)
    opening=rng.choice([
        f'The {site} team reviewed {topic.lower()} during observation window {number}.',
        f'At {site}, the {section.lower()} record covers batch {number} and its adjacent sampling periods.',
        f'Window {number} documents the effect of local conditions on {topic.lower()} at {site}.',
        f'This {section.lower()} entry links the measurements from {site} to the current maintenance decision.'])
    sentences=[
        f'The median reading was {value:.2f}, with a spread of {rng.uniform(.2,8):.2f} across the accepted observations.',
        f'Operators retained {rng.randrange(84,100)} percent of the raw samples and flagged the remainder for a second review.',
        f'A {rng.randrange(2,12)} minute overlap with the reference instrument makes discontinuities visible without changing the original timestamps.',
        'A missing observation stays missing; interpolation is reserved for the separate summary view.',
        'The working copy includes the instrument serial number, local notes, and the reason for every rejected interval.',
        'Read the comparison table before changing a threshold, because a short excursion can reflect a scheduled inspection.',
        'The field operator records weather and access conditions alongside the automated measurements.',
        'The archive preserves both the source values and the calibrated series so later reviews can reproduce the result.',
        'A gradual drift requires a different response from an isolated spike, even when both cross the same display limit.',
        'The handover names the next reviewer and the earliest date on which the adjustment can be checked.',
        'A successful transfer confirms receipt of bytes; the quality gate separately checks sequence numbers and units.',
        'The monitoring view emphasizes sustained changes rather than treating every fluctuation as an incident.',
        'Lorem ipsum dolor sit amet, consectetur adipiscing elit; sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.']
    return opening+' '+' '.join(rng.sample(sentences,5))+'\n\n'


def huge_document():
    directory=ROOT/'assets/sample-huge'
    directory.mkdir(exist_ok=True)
    names=[f'{NAMES[i//10]} {PLACES[i%10]}' for i in range(100)]
    parts=['# Field Operations Handbook — Large Markdown Fixture\n\n',
           'This fictional engineering handbook contains 100 distinct station reports, not copies of the small sample. '
           'Its measurements are deterministic synthetic data, not scientific observations. Each report references its own image exactly once. '
           'PNG charts and diagrams mix with baseline/progressive and color/grayscale JPEG spatial surveys. '
           'Dimensions and compressed sizes vary. All assets are local, so loading requires no network.\n\n',
           'The text is approximately 100 times SAMPLE.md. The regular sample remains the compact syntax-coverage document. '
           'Use `python3 scripts/generate-samples.py` to reproduce this handbook and its synthetic image assets.\n\n',
           '## Station index\n\n']
    parts.extend(f'- [{i+1:03d}: {name}](#station-{i+1:03d}-{name.lower().replace(" ","-")})\n' for i,name in enumerate(names))
    parts.append('\n')
    for i,site in enumerate(names,1):
        rng=random.Random(61200+i)
        topic=TOPICS[(i-1)%10]
        suffix='.jpg' if i%10 in (0,2,5,8) else '.png'
        filename=f'station-{i:03d}{suffix}'
        image(directory/filename,i)
        parts.append(f'## Station {i:03d}: {site}\n\n')
        parts.append(f'**Focus:** {topic}. **Revision:** {1+i%4}. **Review owner:** Team {chr(65+i%8)}.\n\n')
        parts.append(f'[Station index](#station-index) · [Compact syntax sample](SAMPLE.md)\n\n')
        parts.append(f'![{topic} at {site}: distinct synthetic chart or spatial survey {i:03d}.](assets/sample-huge/{filename} "{site} survey")\n\n')
        # Vary section order and Markdown structure without duplicating an
        # entire reference document or its assets a hundred times.
        sections=SECTIONS[i%4:]+SECTIONS[:i%4]
        for j,section in enumerate(sections):
            parts.append(f'### {i:03d}.{j+1} {section}\n\n')
            for k in range(2):
                parts.append(paragraph(rng,site,topic,section,i*100+j*3+k))
            if j%4==0:
                parts.append('| Channel | Accepted | Median | Range | Review |\n|:--|--:|--:|:--:|:--|\n')
                for k in range(4+i%5):
                    parts.append(f'| `{i:03d}-{j}-{k}` | {rng.randrange(800,1440)} | {rng.uniform(3,38):.2f} | {rng.randrange(1,8)}–{rng.randrange(40,90)} | '+('**Inspect**' if k==i%4 else 'Accepted')+' |\n')
                parts.append('\n')
            elif j%4==1:
                parts.append(f'1. Check the `{site.lower().replace(" ","-")}` manifest against the local instrument log.\n'
                             f'2. Compare revision **{1+i%4}** with the previous accepted calibration.\n'
                             '   - Keep raw timestamps and units.\n   - Record an explicit reason for excluded observations.\n'
                             '3. Publish the reviewed series after the second operator signs the checklist.\n\n')
            elif j%4==2:
                languages=[('json',f'{{\n  "station": "S{i:03d}",\n  "interval_seconds": {30+i%6*15},\n  "retention_days": {30+i%5*15},\n  "quality_gate": true\n}}'),
                           ('sh',f'mdf station-{i:03d}-review.md\n# Inspect the local report before the next handover.\nsha256sum station-{i:03d}-measurements.csv'),
                           ('python',f'accepted = [row for row in station_{i:03d} if row.quality >= {80+i%15}]\nmedian = sorted(row.value for row in accepted)[len(accepted) // 2]\nprint(f"Reviewed median: {{median:.2f}}")')]
                lang,body=languages[(i+j)%3]
                parts.append(f'```{lang}\n{body}\n```\n\n')
            else:
                parts.append(f'> **Field note {i:03d}/{j+1}:** A transfer retry is not a new observation.\n'
                             '> Retain the original sequence number and investigate the missing acknowledgement.\n\n')
        parts.append(f'<details>\n<summary>{site} handover checklist</summary>\n\n'
                     '- [x] Source values preserved.\n- [x] Local timestamps reconciled.\n- [ ] Next inspection booked.\n\n'
                     f'The next inspection follows the station {i:03d} maintenance window.[^station-{i:03d}]\n\n</details>\n\n'
                     f'[^station-{i:03d}]: Synthetic station {site}; values and procedures exist only for rendering tests.\n\n---\n\n')
    parts.append('## End of handbook\n\nAll 100 station reports and their distinct local images are above. [Return to the station index](#station-index).\n')
    (ROOT/'SAMPLE-HUGE.md').write_text(''.join(parts))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    image(ROOT/'assets/sample-signal.png',31,0)
    image(ROOT/'assets/sample-pipeline.png',43,3)
    image(ROOT/'assets/sample-survey.jpg',52)
    huge_document()
    for name in ['SAMPLE.md','SAMPLE-HUGE.md']:
        path=ROOT/name
        print(name, f'{path.stat().st_size:,} text bytes', hashlib.sha256(path.read_bytes()).hexdigest())
    paths=list((ROOT/'assets/sample-huge').glob('*'))
    print('Huge assets:',len(paths),f'{sum(p.stat().st_size for p in paths):,} bytes')


if __name__=='__main__':
    main()
