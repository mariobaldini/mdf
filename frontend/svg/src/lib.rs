//! SVG rasterization only. Mermaid parsing/layout is provided by Zig/Pozeiden.
use resvg::{tiny_skia, usvg};
use std::ffi::c_void;
use std::sync::{Arc, OnceLock, atomic::{AtomicBool, Ordering}};

#[repr(C)]
pub struct Buffer { ptr: *const u8, len: usize }
#[repr(C)]
pub struct FontData { data: *const u8, length: usize }
unsafe extern "C" {
        fn mdf_builtin_font(family: u32, style: u32) -> Buffer;
    fn malloc(size: usize) -> *mut c_void;
}

#[repr(C)]
pub struct Pixels { data: *mut u8, width: i32, height: i32, channels: i32 }

fn fonts() -> Arc<usvg::fontdb::Database> {
    static FONTS: OnceLock<Arc<usvg::fontdb::Database>> = OnceLock::new();
    FONTS.get_or_init(|| {
        let mut db = usvg::fontdb::Database::new();
        for style in 0..2 {
            let data = unsafe { mdf_builtin_font(0, style) };
            if !data.ptr.is_null() && data.len != 0 {
                db.load_font_data(unsafe { std::slice::from_raw_parts(data.ptr, data.len) }.to_vec());
            }
        }
        db.set_sans_serif_family("Open Sans");
        db.set_serif_family("Open Sans");
        db.set_monospace_family("Open Sans");
        Arc::new(db)
    }).clone()
}

struct Rendered {
    data: Vec<u8>, width: u32, height: u32,
    logical_width: f32, logical_height: f32,
    #[cfg(test)] label_paths: usize,
}

#[cfg(test)]
fn label_paths(group: &usvg::Group) -> usize {
    group.children().iter().map(|node| match node {
        usvg::Node::Group(child) => label_paths(child),
        usvg::Node::Text(text) => text.flattened().children().len(),
        _ => 0,
    }).sum()
}

fn render_svg_with_fonts(source: &str, limit: usize, extra: &[Arc<Vec<u8>>]) -> Result<Rendered, String> {
    if source.len() > 16 * 1024 * 1024 { return Err("SVG source exceeds 16 MiB".into()); }
    let xml = roxmltree::Document::parse(source).map_err(|e| e.to_string())?;
    if xml.root_element().tag_name().name() != "svg" { return Err("Expected an SVG document".into()); }
    if xml.descendants().take(100_001).count() > 100_000 { return Err("SVG exceeds 100000 XML nodes".into()); }
    for node in xml.descendants().filter(|n| n.is_element()) {
        if matches!(node.tag_name().name(), "image" | "feImage" | "script" | "foreignObject") {
            return Err("SVG embedded images, scripts and foreign objects are unsupported".into());
        }
        for attribute in node.attributes() {
            if node.tag_name().name() != "a" && matches!(attribute.name(), "href" | "src") && !attribute.value().starts_with('#') {
                return Err("SVG external resources are unsupported".into());
            }
        }
        if node.tag_name().name() == "style" && node.text().is_some_and(|t|
            t.contains("@import") || t.contains("@font-face")) {
            return Err("SVG external styles and font loading are unsupported".into());
        }
    }
    rasterize(source, limit, extra)
}

fn rasterize(svg: &str, limit: usize, extra: &[Arc<Vec<u8>>]) -> Result<Rendered, String> {
    let mut fontdb = fonts();
    if !extra.is_empty() {
        let mut extended = (*fontdb).clone();
        for font in extra {
            extended.load_font_source(usvg::fontdb::Source::Binary(font.clone()));
        }
        fontdb = Arc::new(extended);
    }
    let missing_italic = AtomicBool::new(false);
    let default_selector = usvg::FontResolver::default_font_selector();
    let options = usvg::Options {
        font_family: "Open Sans".into(), fontdb,
        font_resolver: usvg::FontResolver {
            select_font: Box::new(|font, db| {
                if font.style() != usvg::FontStyle::Normal {
                    let style = if font.weight() > 500 { 3 } else { 2 };
                    let weight = if style == 3 { 700 } else { 400 };
                    if !db.faces().any(|face| face.style == usvg::fontdb::Style::Italic &&
                        face.weight.0 == weight && face.families.iter().any(|family| family.0 == "Open Sans")) {
                        // usvg resolves inherited CSS styles here. A normal SVG
                        // never requests an italic face from the host.
                        let data = unsafe { mdf_builtin_font(0, style) };
                        if data.ptr.is_null() || data.len == 0 { missing_italic.store(true, Ordering::Relaxed); }
                        else { Arc::make_mut(db).load_font_data(unsafe { std::slice::from_raw_parts(data.ptr, data.len) }.to_vec()); }
                    }
                }
                default_selector(font, db)
            }),
            select_fallback: usvg::FontResolver::default_fallback_selector(),
        },
        // Diagram source cannot cause file/network image resolution. The
        // raster-image decoder and system-font features are also disabled.
        image_href_resolver: usvg::ImageHrefResolver {
            resolve_data: Box::new(|_, _, _| None),
            resolve_string: Box::new(|_, _| None),
        },
        ..Default::default()
    };
    let tree = usvg::Tree::from_str(svg, &options).map_err(|e| e.to_string())?;
    if missing_italic.load(Ordering::Relaxed) { return Err("Cannot prepare required bundled italic font".into()); }
    let logical_width = tree.size().width();
    let logical_height = tree.size().height();
    if !logical_width.is_finite() || !logical_height.is_finite() ||
        logical_width <= 0.0 || logical_height <= 0.0 ||
        logical_width > 16384.0 || logical_height > 16384.0 {
        return Err("Diagram canvas exceeds 16384 pixels".into());
    }
    // Two raster pixels per logical pixel keep labels sharp at desktop scale.
    // Large diagrams use their native resolution within the allocation limit.
    let cap = (limit / 4).min(16 * 1024 * 1024) as f32;
    let scale = (cap / (logical_width * logical_height)).sqrt().min(2.0);
    if scale < 1.0 { return Err("Diagram exceeds the image memory limit".into()); }
    let width = (logical_width * scale).floor().max(1.0) as u32;
    let height = (logical_height * scale).floor().max(1.0) as u32;
    let mut pixmap = tiny_skia::Pixmap::new(width, height).ok_or("Cannot allocate diagram pixels")?;
    resvg::render(&tree, tiny_skia::Transform::from_scale(scale, scale), &mut pixmap.as_mut());
    let mut data = pixmap.take();
    // FLTK expects straight alpha; tiny-skia produces premultiplied RGBA.
    for pixel in data.chunks_exact_mut(4) {
        let alpha = pixel[3] as u32;
        if alpha > 0 && alpha < 255 {
            for value in &mut pixel[..3] {
                *value = ((*value as u32 * 255 + alpha / 2) / alpha).min(255) as u8;
            }
        }
    }
    Ok(Rendered { data, width, height, logical_width, logical_height,
                  #[cfg(test)] label_paths: label_paths(tree.root()) })
}

/// Output pixels use libc malloc/free across the private SVG module ABI.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdf_render_svg(
    source: *const u8, length: usize, _dark: i32, extra_fonts: *const FontData, font_count: usize, limit: usize,
    out: *mut Pixels, logical_width: *mut f32, logical_height: *mut f32,
    error: *mut u8, error_length: usize,
) -> i32 {
    if out.is_null() || logical_width.is_null() || logical_height.is_null() { return 0; }
    unsafe {
        *out = Pixels { data: std::ptr::null_mut(), width: 0, height: 0, channels: 0 };
        *logical_width = 0.0; *logical_height = 0.0;
        if !error.is_null() && error_length > 0 { *error = 0; }
    }
    let result = std::panic::catch_unwind(|| {
        if source.is_null() || length == 0 { return Err("Empty SVG image".into()); }
        if length > 16 * 1024 * 1024 { return Err("SVG source exceeds 16 MiB".into()); }
        if font_count > 256 || (font_count > 0 && extra_fonts.is_null()) { return Err("Invalid prepared SVG fonts".into()); }
        let mut extra = Vec::new();
        if font_count > 0 {
            for font in unsafe { std::slice::from_raw_parts(extra_fonts, font_count) } {
                if font.data.is_null() || font.length == 0 || font.length > 128 * 1024 * 1024 { return Err("Invalid prepared SVG font".into()); }
                extra.push(Arc::new(unsafe { std::slice::from_raw_parts(font.data, font.length) }.to_vec()));
            }
        }
        let source = std::str::from_utf8(unsafe { std::slice::from_raw_parts(source, length) }).map_err(|_| "SVG is not UTF-8")?;
        render_svg_with_fonts(source, limit, &extra)
    }).unwrap_or_else(|_| Err("SVG renderer could not process this image".into()));
    let message = match result {
        Ok(image) => {
            let allocation = unsafe { malloc(image.data.len()) }.cast::<u8>();
            if !allocation.is_null() {
                unsafe {
                    std::ptr::copy_nonoverlapping(image.data.as_ptr(), allocation, image.data.len());
                    *out = Pixels { data: allocation, width: image.width as i32, height: image.height as i32, channels: 4 };
                    *logical_width = image.logical_width; *logical_height = image.logical_height;
                }
                return 1;
            }
            "Cannot allocate SVG pixels".to_string()
        }
        Err(message) => message,
    };
    unsafe { write_error(&message, error, error_length); }
    0
}

unsafe fn write_error(message: &str, error: *mut u8, error_length: usize) {
    if !error.is_null() && error_length > 0 {
        let mut count = message.len().min(error_length - 1);
        while !message.is_char_boundary(count) { count -= 1; }
        unsafe {
            std::ptr::copy_nonoverlapping(message.as_ptr(), error, count);
            *error.add(count) = 0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    thread_local! { static REQUESTED_STYLES: std::cell::Cell<u32> = const { std::cell::Cell::new(0) }; }

    #[unsafe(no_mangle)]
    extern "C" fn mdf_builtin_font(_family: u32, style: u32) -> Buffer {
        REQUESTED_STYLES.with(|requested| requested.set(requested.get() | (1 << style)));
        let fonts: [&[u8]; 4] = [
            include_bytes!("../../../assets/fonts/open-sans/OpenSans-Regular.ttf"),
            include_bytes!("../../../assets/fonts/open-sans/OpenSans-Bold.ttf"),
            include_bytes!("../../../assets/fonts/open-sans/OpenSans-Italic.ttf"),
            include_bytes!("../../../assets/fonts/open-sans/OpenSans-BoldItalic.ttf"),
        ];
        let bytes = fonts[style as usize];
        Buffer { ptr: bytes.as_ptr(), len: bytes.len() }
    }

    #[test]
    fn svg_loads_only_the_italic_face_its_resolved_style_needs() {
        for (attributes, expected) in [("", 0), ("font-style='italic'", 4),
                                      ("style='font-style:italic;font-weight:bold'", 8),
                                      ("style='font-style:italic;font-weight:600'", 8),
                                      ("style='font-style:italic;font-weight:550'", 4)] {
            REQUESTED_STYLES.with(|requested| requested.set(0));
            let source = format!("<svg xmlns='http://www.w3.org/2000/svg' width='200' height='80'><g {attributes}><text x='5' y='40'>Styled text</text></g></svg>");
            let image = render_svg_with_fonts(&source, 64 * 1024 * 1024, &[]).unwrap();
            assert!(image.label_paths > 0);
            REQUESTED_STYLES.with(|requested| assert_eq!(requested.get() & 12, expected));
        }
    }

    #[test]
    fn local_svg_renders_vectors_and_embedded_text() {
        let image = render_svg_with_fonts(r##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60">
          <rect width="120" height="60" fill="#c03020"/>
          <text x="5" y="30" font-size="18" fill="white">MDF SVG</text></svg>"##,
          64 * 1024 * 1024, &[]).unwrap();
        assert_eq!((image.logical_width, image.logical_height), (120.0, 60.0));
        assert_eq!((image.width, image.height), (240, 120));
        assert!(image.label_paths > 0);
        assert_eq!(&image.data[..4], &[192, 48, 32, 255]);
        // Hyperlinks are inert in a raster image; they do not fetch resources.
        assert!(render_svg_with_fonts(r#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><a href="https://example.invalid/"><rect width="10" height="10"/></a></svg>"#,
            4096, &[]).is_ok());
        for source in [
            "not svg", "<html/>",
            r#"<svg xmlns="http://www.w3.org/2000/svg"><image href="file:///tmp/unavailable"/></svg>"#,
            r#"<svg xmlns="http://www.w3.org/2000/svg"><use href="https://example.invalid/object.svg#x"/></svg>"#,
            r#"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#,
            r#"<svg xmlns="http://www.w3.org/2000/svg"><style>@font-face { src: url(font.ttf) }</style></svg>"#,
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="999999" height="60"/>"#,
        ] { assert!(render_svg_with_fonts(source, 64 * 1024 * 1024, &[]).is_err(), "{source}"); }
        assert!(render_svg_with_fonts(r#"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60"/>"#,
            4, &[]).is_err());
    }

    #[test]
    fn invalid_svg_ffi_clears_outputs_and_reports_errors() {
        let mut out = Pixels { data: std::ptr::dangling_mut(), width: 1, height: 1, channels: 4 };
        let (mut width, mut height) = (1.0, 1.0);
        let mut message = [0u8; 64];
        assert_eq!(unsafe { mdf_render_svg(std::ptr::null(), 0, 0, std::ptr::null(), 0, usize::MAX,
            &mut out, &mut width, &mut height, message.as_mut_ptr(), message.len()) }, 0);
        assert!(out.data.is_null() && width == 0.0 && height == 0.0 && message[0] != 0);
    }
}
