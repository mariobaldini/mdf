// MDF's adaptation of the upstream text-measurement seam. All diagrams use the
// same embedded Open Sans as the reader, plus an explicitly prepared optional
// fallback set. No filesystem discovery or font cache.
use std::cell::RefCell;
use std::sync::{Arc, OnceLock};
use ttf_parser::Face;

#[repr(C)]
struct Buffer { ptr: *const u8, len: usize }
unsafe extern "C" { fn mdf_builtin_font(family: u32, style: u32) -> Buffer; }

thread_local! { static FALLBACK: RefCell<Vec<Arc<Vec<u8>>>> = const { RefCell::new(Vec::new()) }; }

pub fn with_fallback_fonts<T>(fonts: &[Arc<Vec<u8>>], operation: impl FnOnce() -> T) -> T {
    struct Restore(Vec<Arc<Vec<u8>>>);
    impl Drop for Restore {
        fn drop(&mut self) { FALLBACK.with(|value| *value.borrow_mut() = std::mem::take(&mut self.0)); }
    }
    let _restore = Restore(FALLBACK.with(|value| value.replace(fonts.to_vec())));
    operation()
}

fn font() -> Option<&'static Face<'static>> {
    static FONT: OnceLock<Option<Face<'static>>> = OnceLock::new();
    FONT.get_or_init(|| {
        // The Zig core owns these immutable bytes for the process lifetime.
        let data = unsafe { mdf_builtin_font(0, 0) };
        if data.ptr.is_null() || data.len == 0 { return None; }
        Face::parse(unsafe { std::slice::from_raw_parts(data.ptr, data.len) }, 0).ok()
    }).as_ref()
}

pub fn measure_text_width(text: &str, size: f32, _family: &str) -> Option<f32> {
    if text.is_empty() || size <= 0.0 { return Some(0.0); }
    let face = font()?;
    FALLBACK.with(|stored| {
        let stored = stored.borrow();
        let extra: Vec<_> = stored.iter().flat_map(|data|
            (0..ttf_parser::fonts_in_collection(data).unwrap_or(1)).filter_map(|index| Face::parse(data, index).ok())
        ).collect();
        let advance = |ch| {
            let chosen = std::iter::once(face).chain(extra.iter()).find_map(|face|
                face.glyph_index(ch).and_then(|id| face.glyph_hor_advance(id))
                    .map(|width| width as f32 * size / face.units_per_em().max(1) as f32));
            chosen.unwrap_or_else(|| face.glyph_hor_advance(ttf_parser::GlyphId(0)).unwrap_or(0) as f32 *
                                  size / face.units_per_em().max(1) as f32)
        };
        Some(text.split('\n').map(|line| line.chars().map(|ch|
            if ch == '\t' { 4.0 * advance(' ') } else { advance(ch) }).sum::<f32>())
            .fold(0.0, f32::max))
    })
}

pub fn average_char_width(family: &str, size: f32) -> Option<f32> {
    measure_text_width("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", size, family)
        .map(|width| width / 52.0)
}
