//! Font-independent private Zignal codec module.
const c = @import("native");
const api: c.struct_MdfImageApi = .{
    .abi = c.MDF_IMAGE_ABI, .size = @sizeOf(c.struct_MdfImageApi),
    .kind = c.MDF_MODULE_IMAGE, .reserved = 0,
    .decode = c.mdf_decode_pixels, .encode = c.mdf_encode_png,
};
pub export fn mdf_image_api(abi: u32) callconv(.c) ?*const c.struct_MdfImageApi {
    return if (abi == c.MDF_IMAGE_ABI) &api else null;
}
