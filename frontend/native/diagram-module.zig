//! Private renderer ABI for native builds. Only the API table is exported;
//! bundled fonts stay owned by the host and are requested one face at a time.
const c = @import("native");
const kind = @import("diagram_options").kind;
var provider: c.MdfBuiltinFont = null;

pub export fn mdf_builtin_font(family: u32, style: u32) callconv(.c) c.Buffer {
    if (family != 0 or style >= 4 or provider == null) return .{ .ptr = null, .len = 0 };
    const font = provider.?(style);
    return .{ .ptr = font.data, .len = font.length };
}
fn initialize(fonts: c.MdfBuiltinFont) callconv(.c) c_int {
    if (fonts == null or (provider != null and provider != fonts)) return 0;
    for (0..2) |style| {
        const font = fonts.?(@intCast(style));
        if (font.data == null or font.length == 0) return 0;
    }
    provider = fonts;
    return 1;
}
extern fn mdf_mermaid_svg([*c]const u8, usize, c_int, [*c]const c.struct_MdfFontData, usize, usize,
    [*c]c.struct_MdfSvgText, [*c]u8, usize) callconv(.c) c_int;
extern fn mdf_render_svg([*c]const u8, usize, c_int, [*c]const c.struct_MdfFontData, usize, usize,
    [*c]c.struct_MdfPixels, [*c]f32, [*c]f32, [*c]u8, usize, [*c]c.struct_MdfSvgText) callconv(.c) c_int;
const api: c.struct_MdfDiagramApi = .{ .abi = c.MDF_DIAGRAM_ABI, .size = @sizeOf(c.struct_MdfDiagramApi),
    .kind = kind, .reserved = 0, .initialize = initialize,
    .mermaid_svg = if (kind == c.MDF_MODULE_MERMAID) mdf_mermaid_svg else null,
    .svg = if (kind == c.MDF_MODULE_SVG) mdf_render_svg else null };
pub export fn mdf_diagram_api(abi: u32) callconv(.c) ?*const c.struct_MdfDiagramApi {
    return if (abi == c.MDF_DIAGRAM_ABI) &api else null;
}
