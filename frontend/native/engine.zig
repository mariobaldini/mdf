//! Private native frontend. Core workers and font bytes belong to the launcher.
const window = @import("native_window");
const c = window.c;
fn run(startup: [*c]c.struct_MdfStartup) callconv(.c) c_int {
    if (startup == null) return 1;
    window.runStartup(startup) catch |err| {
        const message = @errorName(err);
        _ = c.fwrite(message.ptr, 1, message.len, c.stderr);
        _ = c.fwrite("\n", 1, 1, c.stderr);
        return 1;
    };
    return 0;
}
const api: c.struct_MdfFrontendApi = .{ .abi = c.MDF_FRONTEND_ABI, .size = @sizeOf(c.struct_MdfFrontendApi), .run = run };
pub export fn mdf_frontend_api(abi: u32) callconv(.c) ?*const c.struct_MdfFrontendApi {
    return if (abi == c.MDF_FRONTEND_ABI) &api else null;
}
