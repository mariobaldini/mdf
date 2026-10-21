#!/usr/bin/env python3
"""Create one offline HTML with curated MDF/Typora A/B crops.

These notes describe the reviewed SAMPLE.md cases, not an automatic image
classifier. Inspect the input captures before using --reviewed. New renderer
versions need a new review; image/font/editor differences are not all bugs.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import html
import io
from pathlib import Path

FINDINGS = [
    dict(id='table',kind='verified',status='Fixed: narrow table layout',title='Short labels and numbers stay together',case='long-table',width=480,
         mdf=(42,58,418,200),typora=(26,124,442,260),
         observation='MDF now keeps “Short”, “Result” and “12345” intact, matching Typora’s behavior. Long descriptions wrap inside their own column.',
         meaning='The previous unnecessary word splitting is fixed. Column boundaries agree across headers and body rows, including empty cells and styled text.',
         cause='MDF measures word and line widths across all rows using its final fonts. It reserves readable widths for short cells before distributing remaining space.',
         next='Native regression checks cover narrow widths, font-size changes, shared column boundaries and oversized neighboring tokens.'),
    dict(id='font',kind='verified',status='Fixed: deferred system glyph fallback',title='Non-Latin scripts and symbols receive installed fallback glyphs',case='unicode',width=480,
         mdf=(42,210,418,510),typora=(26,230,442,478),
         observation='Greek, Cyrillic, Arabic, Hebrew, Chinese, Japanese and Korean now have visible glyphs in MDF. The sample arrows and emoji also render. Emoji use monochrome outlines here; Typora uses colored glyphs.',
         meaning='The missing-glyph defect is resolved for the reviewed sample on this machine. Coverage depends on installed fonts. Font choice, emoji style and wrapping can differ from Typora. Correct glyphs do not imply correct bidirectional word order; see the remaining finding.',
         cause='The executable keeps the small Latin Open Sans faces. After the first viewport, a Sans worker selects only system families contributing missing document characters. The GUI preserves Latin Open Sans and reflows affected text; code receives the same prepared fallback data. SVG labels retain the separate backend limitations described below.',
         next='Tests cover script/style glyphs, conditional workers, first-frame ordering, code fallback, unavailable fonts and read-only caches. A character without an installed font still shows a missing-glyph marker.'),
    dict(id='bidi',kind='issue',status='Remaining renderer defect',title='Arabic and Hebrew words retain left-to-right sequence',case='unicode',width=480,
         mdf=(42,300,418,375),typora=(26,298,442,365),
         observation='The Arabic and Hebrew letters now shape within each word, but MDF places the two words in source order from left to right. Typora orders the phrase from right to left.',
         meaning='This is a text-layout defect, separate from font coverage. Installing a broader font does not correct paragraph-level bidirectional ordering.',
         cause='MDF lays out separate whitespace-delimited runs. Pango shapes each run, but cannot reorder neighboring words across those separate layouts.',
         next='Use paragraph-level bidirectional layout with matching line wrapping, hit testing and selection. This font-loading change does not implement that larger layout correction.'),
    dict(id='mermaid',kind='verified',status='Added: native Mermaid rendering',title='Mermaid renders as a diagram',case='mermaid',width=480,
         mdf=(42,58,418,155),typora=(26,130,442,245),
         observation='MDF now displays the fenced Mermaid flowchart as nodes, arrows and labels. Typora renders the same source as a diagram; spacing and routing differ.',
         meaning='The source-only limitation is resolved for supported diagrams. This comparison checks the sample flowchart, not pixel equality or every Mermaid feature.',
         cause='Pozeiden calculates Mermaid layout in Zig with estimated label widths. The independent zig-svg/z2d module rasterizes its SVG with bundled Open Sans. Both modules run offline after the first viewport. Sequence separators now emit a valid italic style.',
         next='All 17 Pozeiden families have light/dark raster checks. SVG labels currently lack automatic glyph fallback and Arabic shaping; RTL/vertical text and some font formats produce errors. Journey, packet, architecture, treemap, radar and ZenUML retain source with an error. Embedded images, Markdown labels and newer shape declarations remain unsupported. Review fresh images before applying these annotations.'),
    dict(id='code',kind='verified',status='Fixed: deferred system monospace',title='Code switches to system monospace after its first frame',case='code',width=1040,
         mdf=(108,150,910,450),typora=(120,135,908,440),
         observation='Both applications now show code with fixed character advances and preserved indentation. MDF uses the installed system monospace family; the chosen face and spacing can differ from Typora.',
         meaning='The proportional-code limitation is resolved when a system monospace is available. The first Markdown frame remains Open Sans; the background result then reflows affected code.',
         cause='Code blocks trigger a separate monospace worker after the first viewport. Inline code uses the result when available but does not itself trigger font discovery. Selected Sans faces supply glyphs missing from the code font.',
         next='Native tests cover styles, four-cell tabs, selection positions, private maps, conditional discovery, missing-font fallback and read-only caches. MDF still uses uniform code colors rather than syntax highlighting.'),
    dict(id='details',kind='reference',status='Reference editing-view difference',title='Collapsible HTML exposes different content',case='details',width=480,
         mdf=(42,70,418,265),typora=(26,125,442,452),
         observation='MDF hides the first collapsed section and honors the second section’s open attribute. Typora’s captured editing view exposes the first section’s body and a closing HTML tag.',
         meaning='This is not evidence that MDF lost the hidden content. MDF’s native tests check disclosure toggling and nested sections.',
         cause='Typora is a live Markdown editor. The captured editing representation is not a normative browser rendering of raw HTML.',
         next='Compare disclosure interactions and expanded states separately if exact HTML behavior needs testing.'),
    dict(id='notes',kind='reference',status='Reference display difference',title='Footnote references use different labels',case='footnotes',width=480,
         mdf=(42,65,418,267),typora=(26,120,442,304),
         observation='MDF displays numbered links such as [1] and [2]. Typora’s captured editor displays the source labels sample-note and long-note in small boxes.',
         meaning='Both expose the references, but their visual treatment differs. These screenshots alone do not establish a footnote bug in MDF or identify the responsible Typora preference.',
         cause='Footnotes are an extension with editor-specific presentation. Do not assume Typora’s default editing display is the required appearance.',
         next='Test links, repeated references and return navigation by interaction; the screenshots primarily document presentation.'),
]


def data_url(path, box=None):
    from PIL import Image
    with Image.open(path) as source:
        image=source.convert('RGB')
        if box:
            if not (0<=box[0]<box[2]<=image.width and 0<=box[1]<box[3]<=image.height):
                raise ValueError('Crop outside screenshot: '+str(path))
            image=image.crop(box)
        stream=io.BytesIO();image.save(stream,format='PNG',optimize=True)
        return 'data:image/png;base64,'+base64.b64encode(stream.getvalue()).decode(),image.width,image.height


def pair(directory,case,width,boxes=None):
    figures=[]
    for index,(app,label) in enumerate([('mdf','A · MDF'),('typora','B · Typora')]):
        path=directory/str(width)/(case+'-'+app+'.png')
        uri,w,h=data_url(path,boxes[index] if boxes else None)
        figures.append(f'<figure><figcaption>{label} <small>{w} × {h} px'+(' crop' if boxes else ' original')+'</small></figcaption>'+
                       f'<div class="image-scroll"><img loading="lazy" data-width="{w}" src="{uri}" alt="{html.escape(label+" "+case)}"></div></figure>')
    return '<div class="pair">'+''.join(figures)+'</div>'


def generate(captures,images,output,reviewed):
    remaining=[]
    resolved=[]
    for finding in FINDINGS:
        key=finding['id'];status=finding['status'] if reviewed else 'Draft — review required'
        content=f'<article id="{key}" data-kind="{finding["kind"]}"><div class="finding-head"><span class="tag {finding["kind"]}">{status}</span><span>{finding["width"]} px window</span></div><h2>{html.escape(finding["title"])}</h2>'
        content+='<p>'+html.escape(finding['observation'])+'</p>'
        content+='<div class="zoom"><span>Detail zoom</span>'+''.join(f'<button type="button" data-zoom="{z}" aria-pressed="{str(z==1).lower()}">{z}×</button>' for z in [1,1.5,2,3])+'</div>'
        content+=pair(captures,finding['case'],finding['width'],[finding['mdf'],finding['typora']])
        content+='<div class="assessment"><p><strong>Assessment.</strong> '+html.escape(finding['meaning'])+'</p><p><strong>Reason.</strong> '+html.escape(finding['cause'])+'</p><p><strong>Next step.</strong> '+html.escape(finding['next'])+'</p></div>'
        content+='<details><summary>Original screenshots and full context</summary>'+pair(captures,finding['case'],finding['width'])+'</details></article>'
        (resolved if finding['kind']=='verified' else remaining).append(content)
    if images:
        resolved.append('<article id="images" data-kind="verified"><span class="tag verified">Regression check passed</span><h2>PNG/JPEG decoding remains intact</h2><p>The current background decoder matched FLTK’s decoded pixels exactly for all 106 local PNG/JPEG fixtures, including palette/alpha PNGs and grayscale/progressive JPEGs. The native GUI also loaded all five sample images. This checks the decoder change; it is not a claim that every image layout is identical to Typora.</p>'+pair(images,'images',480,[(42,145,418,490),(26,153,442,475)])+'</article>')
    sources=[captures/'document'/name for name in ('SAMPLE.md','SAMPLE-EXTENDED.md')]
    input_hashes='<br>'.join(html.escape(source.name)+': <code>'+hashlib.sha256(source.read_bytes()).hexdigest()+'</code>'
                            for source in sources if source.is_file())
    binary_hash=hashlib.sha256((captures/'mdf').read_bytes()).hexdigest()
    status='Reviewed findings' if reviewed else 'Draft findings — manual review required'
    content='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MDF / Typora — rendering findings</title><link rel="icon" href="data:,"><style>
:root{color-scheme:dark;--bg:#141c27;--paper:#1d2938;--ink:#e5ebf3;--muted:#afbdce;--line:#3b4a5d}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 system-ui,sans-serif}main{max-width:1320px;margin:auto;padding:36px 28px 70px}h1{font-size:30px;letter-spacing:-.7px;margin:0}h2{font-size:23px;line-height:1.3;margin:12px 0}p{max-width:1100px;margin:10px 0;color:var(--muted)}header{border-bottom:2px solid var(--line);padding-bottom:24px}.lead{font-size:18px;color:var(--ink)}nav,.zoom,.finding-head{display:flex;gap:9px;align-items:center;flex-wrap:wrap}nav{margin:24px 0}button{font:inherit;color:var(--ink);border:1px solid var(--line);background:transparent;border-radius:4px;padding:5px 12px;cursor:pointer}button[aria-pressed=true]{border-color:#8db7ff;background:#263d5b}.finding-head{justify-content:space-between;color:var(--muted);font-size:13px}.tag{border:1px solid;padding:3px 8px;border-radius:3px}.issue{color:#ffaaa6}.limit{color:#f4ca84}.style{color:#a9c8ff}.reference{color:#d5b7f6}.verified{color:#9ed7b7}article{padding:27px 0 34px;border-bottom:1px solid var(--line)}.pair{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:18px;margin:14px 0}figure{margin:0;min-width:0}figcaption{font-weight:600;background:var(--paper);border:1px solid var(--line);padding:8px 12px}figcaption small{font-size:12px;font-weight:400;color:var(--muted);margin-left:8px}.image-scroll{overflow:auto;max-height:660px;background:#fff;border:1px solid var(--line);border-top:0;scrollbar-width:auto}img{display:block;max-width:100%;height:auto;margin:0 auto}article[data-zoomed=true]>.pair img{max-width:none;margin:0}.zoom{margin-top:16px}.zoom span{font-size:13px;color:var(--muted);margin-right:6px}.zoom button{padding:3px 10px;font-size:13px}.assessment{border-left:3px solid var(--line);padding:0 15px}strong{color:var(--ink)}details{margin-top:20px}summary{cursor:pointer;color:var(--muted)}details img{max-width:100%!important;width:auto!important}code{font:12px ui-monospace,monospace;overflow-wrap:anywhere}a{color:#9ec2ff}footer{margin-top:30px;color:var(--muted);font-size:12px}article[hidden]{display:none}@media(max-width:760px){main{padding:22px 14px}.pair{grid-template-columns:1fr}h1{font-size:25px}}
</style><main><header><h1>MDF / Typora · rendering findings</h1>'''
    content+=f'<p>{status}</p><p class="lead">What remains: bidirectional word ordering, installed-font coverage, SVG text coverage and shaping, native Mermaid compatibility limits, code colors, and two reference-editor differences. Table layout, sample body glyph boxes, monospace code and the sample Mermaid flowchart are resolved in the reviewed examples.</p>'
    content+='<p><strong>Remaining renderer defect:</strong> Arabic and Hebrew words are not reordered across separate body text runs. <strong>Feature limits:</strong> body characters without an installed font still show boxes; emoji appearance follows the selected fallback font. SVG labels lack automatic per-character fallback and Arabic shaping; RTL/vertical layout and some font formats produce errors. Embedded images inside Mermaid diagrams are unsupported, and advanced syntax may differ from official Mermaid. Syntax highlighting is not implemented. Footnote labels and collapsible HTML differ in Typora’s editing view; those captures do not establish MDF defects.</p>'
    content+='<p>These are real application captures of the same Markdown bytes, with A/B crops focused on the differences. Nothing here is an AI-generated mockup. Use 2× or 3× to inspect details and scroll inside a magnified panel. Each finding includes the original screenshots.</p></header>'
    content+='<nav aria-label="Filter findings">'+''.join(f'<button type="button" data-filter="{key}" aria-pressed="{str(key=="all").lower()}">{label}</button>' for key,label in [('all','All findings'),('issue','Renderer defects'),('limit','Known limits'),('style','Styling'),('reference','Reference differences'),('verified','Fixes / checks')] if key=='all' or any(f['kind']==key for f in FINDINGS))+'</nav>'
    content+='<section data-findings-group><h2>Remaining findings</h2>'+''.join(remaining)+'</section>'
    content+='<section data-findings-group><h2>Resolved and verified</h2>'+''.join(resolved)+'</section>'
    count=len(list(captures.glob('*/*-mdf.png')))
    content+=f'<section><h2>Method and limits</h2><p>This focused review captured {count} section pairs at 1040 and 480 logical pixels. MDF uses its native optimized renderer, bundled Latin fonts, deferred system fonts and default settings. Typora uses its installed Flatpak, a disposable default profile and its normal live editing view. Flatpak is used only to launch Typora.</p><p>MDF’s screenshots capture its reader region; Typora’s originals include menu/status bars. Crops remove that chrome and align the relevant content. Default fonts, sizes, content margins and editing markers differ. Typora is a reference implementation, not an unquestionable oracle. No claim is based on a pixel-difference percentage.</p><p>The table change has native font/viewport regression checks. Mermaid has native layout/raster checks. Font checks verify the installed glyphs across styles and deferred filesystem access. The exact Typora preference behind its footnote display was not established. No general claim of semantic equivalence or absence of bugs follows from these screenshots.</p>'
    content+=f'<p>Capture: <code>{html.escape(captures.name)}</code><br>Markdown SHA-256:<br>{input_hashes}<br>Captured MDF SHA-256: <code>{binary_hash}</code></p></section>'
    content+='<footer>All images, styles and controls are embedded in this file. It works offline and can be shared as one HTML file. Review annotations before reusing them with a changed renderer.</footer></main>'
    content+='''<script>
document.querySelectorAll('[data-filter]').forEach(button=>button.addEventListener('click',()=>{const value=button.dataset.filter;document.querySelectorAll('article[data-kind]').forEach(article=>article.hidden=value!=='all'&&article.dataset.kind!==value);document.querySelectorAll('[data-findings-group]').forEach(group=>group.hidden=![...group.querySelectorAll('article')].some(article=>!article.hidden));document.querySelectorAll('[data-filter]').forEach(item=>item.setAttribute('aria-pressed',String(item===button)));}));
document.querySelectorAll('[data-zoom]').forEach(button=>button.addEventListener('click',()=>{const article=button.closest('article'),zoom=Number(button.dataset.zoom);article.dataset.zoomed=String(zoom!==1);article.querySelectorAll(':scope > .pair img').forEach(image=>image.style.width=`${image.dataset.width*zoom}px`);article.querySelectorAll('[data-zoom]').forEach(item=>item.setAttribute('aria-pressed',String(item===button)));}));
</script></html>'''
    stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    destination=output.with_name(output.stem+'-'+stamp+'.html')
    destination.parent.mkdir(parents=True,exist_ok=True)
    destination.write_text(content)
    print('Unified A/B findings:',destination,flush=True)
    return destination


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures',type=Path)
    parser.add_argument('--images-captures',type=Path)
    parser.add_argument('--output',type=Path,default=Path('build/render-comparison/findings.html'))
    parser.add_argument('--reviewed',action='store_true',help='Assert the supplied captures were manually reviewed; otherwise label the report a draft')
    args=parser.parse_args()
    generate(args.captures.resolve(),args.images_captures.resolve() if args.images_captures else None,args.output.resolve(),args.reviewed)


if __name__=='__main__':main()
