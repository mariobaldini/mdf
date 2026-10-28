#!/usr/bin/env python3
"""Create matched TEXT/IMAGES workloads without regenerating raster assets."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
SIZES = ('SMALL', 'MID', 'HUGE')


def text_only(source):
    source = re.sub(r'\n## Visual appendix\n.*\Z', '\n', source, flags=re.S)
    # Existing syntax fixtures keep nested Markdown fences. Only a genuine
    # Mermaid fence at the start of a line is removed here.
    source = re.sub(r'^```mermaid[^\n]*\n.*?^```\s*$', '', source, flags=re.M | re.S)
    # The regular fixture groups image/reference examples into one section.
    source = re.sub(r'^## Images\n.*?(?=^## Code\n)', '', source, flags=re.M | re.S)
    source = re.sub(r'^!\[[^\n]*\n', '', source, flags=re.M)
    # Reference definitions are unused after removing the image section.
    source = re.sub(r'^\[sample-(?:signal|pipeline|survey)\]:[^\n]*\n', '', source, flags=re.M)
    return re.sub(r'\n{4,}', '\n\n\n', source).rstrip() + '\n'


def visuals(size):
    # Every image edition includes all three optional modules, independently
    # of the amount of prose. The handbook retains its 100 unique rasters.
    raster = '' if size == 'HUGE' else (
        '![Observation chart](../sample-signal.png)\n\n'
        '![Earth rising above the lunar horizon](../sample-earthrise.jpg)\n\n')
    if size == 'MID':
        raster += ('![Processing pipeline](../sample-pipeline.png)\n\n'
                   '![Synthetic spatial survey](../sample-survey.jpg)\n\n'
                   '![Shapes](../sample-shapes.png)\n\n')
    return ('\n## Visual appendix\n\n' + raster +
            '![Local SVG observation diagram](../sample-vector.svg)\n\n'
            '```mermaid\nflowchart LR\n'
            '    A[Read Markdown] --> B[Show text]\n'
            '    B --> C[Load needed images]\n'
            '    C --> D[Ready]\n```\n')


def generate(root=ROOT):
    samples = root/'assets/samples'
    originals = {'SMALL': 'SAMPLE-SMALL.md', 'MID': 'SAMPLE.md', 'HUGE': 'SAMPLE-HUGE.md'}
    result = {}
    for size, original in originals.items():
        source = (samples/original).read_text()
        if size == 'SMALL':
            source = source.replace('It contains no images, diagrams, italic text, or code blocks.',
                                    'The paired image edition adds a separate visual appendix.')
        if size == 'HUGE':
            source = source.replace('Each report references its own image exactly once.',
                                    'The paired image edition adds one distinct raster per report.')
            source = source.replace('All 100 station reports and their distinct local images are above.',
                                    'All 100 distinct station reports are above.')
        prose = text_only(source)
        for edition in ('TEXT', 'IMAGES'):
            if edition == 'TEXT':
                content = prose
            elif size == 'HUGE':
                content = source.rstrip() + '\n' + visuals(size)
            else:
                content = prose + visuals(size)
            path = samples/f'SAMPLE-{size}-{edition}.md'
            # Do not change mtimes for a no-op regeneration.
            if not path.is_file() or path.read_text() != content:
                path.write_text(content)
            result[path.name] = content
    return result


if __name__ == '__main__':
    for name, text in generate().items():
        print(name, f'{len(text.encode()):,} bytes')
