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
         mdf=(46,135,414,470),typora=(30,126,438,423),
         observation='MDF now keeps “Short”, “Result” and “12345” intact, matching Typora’s behavior. Long descriptions wrap inside their own column.',
         meaning='The previous unnecessary word splitting is fixed. Column boundaries agree across headers and body rows, including empty cells and styled text.',
         cause='MDF measures word and line widths across all rows using its final fonts. It reserves readable widths for short cells before distributing remaining space.',
         next='Native regression checks cover narrow widths, font-size changes, shared column boundaries and oversized neighboring tokens.'),
    dict(id='font',kind='verified',status='Fixed: deferred system glyph fallback',title='Non-Latin scripts and symbols receive installed fallback glyphs',case='unicode',width=480,
         mdf=(46,280,414,701),typora=(30,266,438,658),
         observation='Greek, Cyrillic, Arabic, Hebrew, Chinese, Japanese and Korean now have visible glyphs in MDF. The sample arrows and emoji also render. Emoji use monochrome outlines here; Typora uses colored glyphs.',
         meaning='The missing-glyph defect is resolved for the reviewed sample on this machine. Coverage depends on installed fonts. Font choice, emoji style and wrapping can differ from Typora. Correct glyphs do not imply correct bidirectional word order; see the remaining finding.',
         cause='The executable keeps the small Latin Open Sans faces. After the first viewport, a Sans worker selects only system families contributing missing document characters. The GUI preserves Latin Open Sans and reflows affected text; code receives the same prepared fallback data. SVG labels retain the separate backend limitations described below.',
         next='Tests cover script/style glyphs, conditional workers, first-frame ordering, code fallback, unavailable fonts and read-only caches. A character without an installed font still shows a missing-glyph marker.'),
    dict(id='bidi',kind='limit',status='Deferred: outside current Latin scope',title='Arabic and Hebrew words retain left-to-right sequence',case='unicode',width=480,
         mdf=(46,378,414,446),typora=(30,341,438,408),
         observation='The Arabic and Hebrew letters now shape within each word, but MDF places the two words in source order from left to right. Typora orders the phrase from right to left.',
         meaning='This is a text-layout defect, separate from font coverage. Installing a broader font does not correct paragraph-level bidirectional ordering.',
         cause='MDF lays out separate whitespace-delimited runs. Pango shapes each run, but cannot reorder neighboring words across those separate layouts.',
         next='Deferred by scope: current work targets Latin text only. Broader script layout needs separate paragraph-level ordering, wrapping, hit-testing and selection work.'),
    dict(id='mermaid',kind='verified',status='Added: native Mermaid rendering',title='Mermaid renders as a diagram',case='mermaid',width=480,
         mdf=(46,132,460,510),typora=(30,135,438,227),
         observation='MDF displays the fenced Mermaid flowchart as nodes, arrows and labels at natural size. This narrow crop shows the first part; the rest remains reachable by panning or Fit. Typora fits the same source into its column; spacing and routing differ.',
         meaning='The source-only limitation is resolved for supported diagrams. This comparison checks the sample flowchart, not pixel equality or every Mermaid feature.',
         cause='Pozeiden calculates Mermaid layout in Zig with estimated label widths. The independent zig-svg/z2d module rasterizes its SVG with bundled Open Sans. Both modules run offline after the first viewport. Sequence separators now emit a valid italic style.',
         next='All 17 Pozeiden families have light/dark raster checks. SVG labels can use deferred prepared Sans fonts, including XML-entity/tspan characters. Complex-script shaping, whole-run font selection, RTL/vertical text and some font formats remain limited. Journey, packet, architecture, treemap, radar and ZenUML retain source with an error. Embedded images, Markdown labels and newer shape declarations remain unsupported.'),
    dict(id='wide-table',kind='verified',status='Fixed: readable table overflow',title='Wide tables keep readable columns while ordinary text stays wrapped',case='wide-table',width=480,
         mdf=(46,300,414,756),typora=(30,296,438,750),
         observation='At 480 pixels, the table preserves ordinary header words instead of stacking their letters. Columns beyond the viewport remain reachable through the body scrollbar. Typora also retains readable columns and horizontal overflow.',
         meaning='The many-column layout defect is fixed. Wrap remains enabled for paragraphs and cell text. Individual oversized tokens can still break, and only the document body pans; its TOC and minimap stay in place.',
         cause='The allocator retains measured word widths when several readable columns cannot fit together. The native reader derives overflow from encountered table layouts and exposes its existing 20-pixel body scrollbar without measuring all offscreen blocks.',
         next='Core tests cover compact cells, oversized tokens and narrow/wide allocations. Private Wayland checks cover 8-, 16- and 24-column tables, keyboard and wheel panning, and reaching the last column with the scrollbar. Startup benchmarking is deferred.'),
    dict(id='diagram-scale',kind='verified',status='Fixed: natural diagram scale with zoom and pan',title='Wide diagrams keep readable labels in narrow documents',case='mermaid',width=480,
         mdf=(46,132,460,510),typora=(30,135,438,227),
         observation='MDF preserves the sample SVG’s 14-pixel node labels and 12-pixel edge labels at 100%. The inline controls zoom, reset and Fit the whole graph. Dragging, arrow keys and the body scrollbar reveal nodes beyond the viewport. The controls remain visible while panning.',
         meaning='Automatic shrinking no longer makes this wide diagram unreadable. Fit is an explicit overview choice. A narrow natural-size viewport intentionally shows only part of the graph. Routing still differs from Typora, and supported-syntax limits remain.',
         cause='Each diagram has independent view state. Zoom changes reuse its prepared raster and update one block’s geometry; no Mermaid generation or SVG decoding repeats. Ordinary paragraphs stay wrapped and navigation stays fixed.',
         next='Core and private Wayland checks cover natural/Fit geometry, zoom bounds, buttons, keyboard input, dragging, the right edge, pixel reuse, separate figures, light/dark themes and stale drags after an outside release. Startup benchmarks remain deferred.'),
    dict(id='code',kind='verified',status='Fixed: deferred system monospace',title='Code switches to system monospace after its first frame',case='code',width=1040,
         mdf=(102,217,918,510),typora=(114,177,914,423),
         observation='Both applications now show code with fixed character advances and preserved indentation. MDF uses the installed system monospace family; the chosen face and spacing can differ from Typora.',
         meaning='The proportional-code limitation is resolved when a system monospace is available. The first Markdown frame remains Open Sans; the background result then reflows affected code.',
         cause='Code blocks trigger a separate monospace worker after the first viewport. Inline code uses the result when available but does not itself trigger font discovery. Selected Sans faces supply glyphs missing from the code font.',
         next='Native tests cover styles, four-cell tabs, selection positions, private maps, conditional discovery, missing-font fallback and read-only caches. MDF still uses uniform code colors rather than syntax highlighting.'),
    dict(id='details',kind='reference',status='Reference editing-view difference',title='Collapsible HTML exposes different content',case='details',width=480,
         mdf=(46,150,414,340),typora=(30,126,438,580),
         observation='MDF hides the first collapsed section and honors the second section’s open attribute. Typora’s captured editing view exposes the first section’s body and a closing HTML tag.',
         meaning='This is not evidence that MDF lost the hidden content. MDF’s native tests check disclosure toggling and nested sections.',
         cause='Typora is a live Markdown editor. The captured editing representation is not a normative browser rendering of raw HTML.',
         next='Compare disclosure interactions and expanded states separately if exact HTML behavior needs testing.'),
    dict(id='notes',kind='reference',status='Reference display difference',title='Footnote references use different labels',case='footnotes',width=480,
         mdf=(46,136,414,315),typora=(30,120,438,278),
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


def generate(captures,images,output,reviewed,latin_only=False):
    remaining=[]
    resolved=[]
    findings=[finding for finding in FINDINGS if not latin_only or finding['case']!='unicode']
    for finding in findings:
        key=finding['id'];status=finding['status'] if reviewed else 'Draft — review required'
        content=f'<article id="{key}" data-kind="{finding["kind"]}"><div class="finding-head"><span class="tag {finding["kind"]}">{status}</span><span>{finding["width"]} px window</span></div><h2>{html.escape(finding["title"])}</h2>'
        content+='<p>'+html.escape(finding['observation'])+'</p>'
        content+='<div class="zoom"><span>Detail zoom</span>'+''.join(f'<button type="button" data-zoom="{z}" aria-pressed="{str(z==1).lower()}">{z}×</button>' for z in [1,1.5,2,3])+'</div>'
        content+=pair(captures,finding['case'],finding['width'],[finding['mdf'],finding['typora']])
        content+='<div class="assessment"><p><strong>Assessment.</strong> '+html.escape(finding['meaning'])+'</p><p><strong>Reason.</strong> '+html.escape(finding['cause'])+'</p><p><strong>Next step.</strong> '+html.escape(finding['next'])+'</p></div>'
        content+='<details><summary>Original screenshots and full context</summary>'+pair(captures,finding['case'],finding['width'])+'</details>'
        if key=='diagram-scale':
            content+='<details><summary>Wide view: all nodes at natural size in MDF</summary>'+pair(captures,'mermaid',1040)+'</details>'
        content+='</article>'
        (resolved if finding['kind']=='verified' else remaining).append(content)
    if images:
        resolved.append('<article id="images" data-kind="verified"><span class="tag verified">Regression check passed</span><h2>PNG/JPEG decoding remains intact</h2><p>The native GUI loads all five distinct sample images. The independent codec suite covers 158 PNG/JPEG fixtures: PNG pixels match exactly, while JPEG checks bound mean error and require at least 40 dB PSNR. These captures preserve the Earthrise image and proportions; margins differ from Typora.</p>'+pair(images,'images',480,[(46,244,414,452),(30,190,434,418)])+'</article>')
    samples=captures/'document/assets/samples'
    if not samples.is_dir():
        samples=captures/'document/docs/samples'
        if not samples.is_dir():
            samples=captures/'document'
    sources=[samples/name for name in ('SAMPLE.md','SAMPLE-EXTENDED.md')]
    input_hashes='<br>'.join(html.escape(source.name)+': <code>'+hashlib.sha256(source.read_bytes()).hexdigest()+'</code>'
                            for source in sources if source.is_file())
    binary_hash=hashlib.sha256((captures/'mdf').read_bytes()).hexdigest()
    status='Reviewed findings' if reviewed else 'Draft findings — manual review required'
    content='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MDF / Typora — rendering findings</title><link rel="icon" href="data:,"><style>
:root{color-scheme:dark;--bg:#141c27;--paper:#1d2938;--ink:#e5ebf3;--muted:#afbdce;--line:#3b4a5d}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 system-ui,sans-serif}main{max-width:1320px;margin:auto;padding:36px 28px 70px}h1{font-size:30px;letter-spacing:-.7px;margin:0}h2{font-size:23px;line-height:1.3;margin:12px 0}p{max-width:1100px;margin:10px 0;color:var(--muted)}header{border-bottom:2px solid var(--line);padding-bottom:24px}.lead{font-size:18px;color:var(--ink)}nav,.zoom,.finding-head{display:flex;gap:9px;align-items:center;flex-wrap:wrap}nav{margin:24px 0}button{font:inherit;color:var(--ink);border:1px solid var(--line);background:transparent;border-radius:4px;padding:5px 12px;cursor:pointer}button[aria-pressed=true]{border-color:#8db7ff;background:#263d5b}.finding-head{justify-content:space-between;color:var(--muted);font-size:13px}.tag{border:1px solid;padding:3px 8px;border-radius:3px}.issue{color:#ffaaa6}.limit{color:#f4ca84}.style{color:#a9c8ff}.reference{color:#d5b7f6}.verified{color:#9ed7b7}article{padding:27px 0 34px;border-bottom:1px solid var(--line)}.pair{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:18px;margin:14px 0}figure{margin:0;min-width:0}figcaption{font-weight:600;background:var(--paper);border:1px solid var(--line);padding:8px 12px}figcaption small{font-size:12px;font-weight:400;color:var(--muted);margin-left:8px}.image-scroll{overflow:auto;max-height:660px;background:#fff;border:1px solid var(--line);border-top:0;scrollbar-width:auto}img{display:block;max-width:100%;height:auto;margin:0 auto}article[data-zoomed=true]>.pair img{max-width:none;margin:0}.zoom{margin-top:16px}.zoom span{font-size:13px;color:var(--muted);margin-right:6px}.zoom button{padding:3px 10px;font-size:13px}.assessment{border-left:3px solid var(--line);padding:0 15px}strong{color:var(--ink)}details{margin-top:20px}summary{cursor:pointer;color:var(--muted)}details img{max-width:100%!important;width:auto!important}code{font:12px ui-monospace,monospace;overflow-wrap:anywhere}a{color:#9ec2ff}footer{margin-top:30px;color:var(--muted);font-size:12px}article[hidden]{display:none}@media(max-width:760px){main{padding:22px 14px}.pair{grid-template-columns:1fr}h1{font-size:25px}}
</style><main><header><h1>MDF / Typora · rendering findings</h1>'''
    scope_note='Broader script support is outside this review.' if latin_only else 'Extended-script observations are retained below as deferred limits.'
    content+=f'<p>{status}</p><p class="lead">Current support work targets Latin text. Wide tables retain readable columns with horizontal scrolling, and Mermaid diagrams preserve natural label size with zoom and pan. Ordinary prose stays wrapped. Compact tables, monospace code and PNG/JPEG images work in the reviewed captures. What remains: Mermaid compatibility limits and code colors. {scope_note}</p>'
    content+='<p><strong>Feature limits:</strong> choosing Fit can still make a large diagram small; 100% and zoom restore its readable view. Embedded images inside Mermaid diagrams and advanced syntax remain limited. Syntax highlighting is not implemented. Broader script support is deferred outside the current Latin scope. SVG labels retain limits around whole-run font selection and some font formats. Footnotes and collapsible HTML differ in Typora’s editing view; these captures alone do not establish MDF defects for those cases.</p>'
    content+='<p>These are real application captures of the same Markdown bytes, with A/B crops focused on the differences. Nothing here is an AI-generated mockup. Use 2× or 3× to inspect details and scroll inside a magnified panel. Each finding includes the original screenshots.</p></header>'
    content+='<nav aria-label="Filter findings">'+''.join(f'<button type="button" data-filter="{key}" aria-pressed="{str(key=="all").lower()}">{label}</button>' for key,label in [('all','All findings'),('issue','Renderer defects'),('limit','Known limits'),('style','Styling'),('reference','Reference differences'),('verified','Fixes / checks')] if key=='all' or any(f['kind']==key for f in findings))+'</nav>'
    content+='<section data-findings-group><h2>Remaining findings</h2>'+''.join(remaining)+'</section>'
    content+='<section data-findings-group><h2>Resolved and verified</h2>'+''.join(resolved)+'</section>'
    count=len(list(captures.glob('*/*-mdf.png')))
    content+=f'<section><h2>Method and limits</h2><p>This focused review captured {count} section pairs at 1040 and 480 logical pixels. MDF uses its native optimized renderer, bundled Latin fonts, deferred system monospace and default settings. Typora uses its installed Flatpak, a disposable default profile and its normal live editing view. Flatpak is used only to launch Typora.</p><p>Both originals retain application chrome. MDF hides its TOC and minimap; Typora retains its normal editor menu and status bar. Crops omit chrome and focus on the relevant content. Default fonts, sizes, margins and editing markers differ. Typora is a reference implementation, not an unquestionable oracle. No claim is based on a pixel-difference percentage.</p><p>Compact and many-column tables have allocator and native input regression checks. Mermaid has native layout/raster checks. Font checks cover deferred discovery and monospace advances. The exact Typora preference behind its footnote display was not established. No general claim of semantic equivalence or absence of bugs follows from these screenshots. These captures are correctness checks; no startup benchmark was run.</p>'
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
    parser.add_argument('--latin-only',action='store_true',help='Omit extended-script observations outside the current support scope')
    args=parser.parse_args()
    generate(args.captures.resolve(),args.images_captures.resolve() if args.images_captures else None,args.output.resolve(),args.reviewed,args.latin_only)


if __name__=='__main__':main()
