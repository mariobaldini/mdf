const std = @import("std");
const z = @import("zigmark");
const c = @import("stdio");
fn render(gfm: bool) !void {
    const a = std.heap.c_allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const count = c.fread(&buffer, 1, buffer.len, c.stdin);
        if (count == 0) break;
        try input.appendSlice(a, buffer[0..count]);
        if (input.items.len > 64 * 1024 * 1024) return error.InputTooLarge;
    }
    if (c.ferror(c.stdin) != 0) return error.CannotReadInput;
    var doc = try (z.Parser{ .gfm = gfm, .max_input_bytes = 64 * 1024 * 1024 }).parseMarkdown(a, input.items);
    defer doc.deinit(a);
    const output = try z.HTML.render(a, doc);
    defer a.free(output);
    if (c.fwrite(output.ptr, 1, output.len, c.stdout) != output.len) return error.CannotWriteHtml;
}
pub export fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    render(argc > 1 and std.mem.eql(u8, std.mem.span(argv[1]), "gfm")) catch |err| {
        const message = @errorName(err);
        _ = c.fwrite(message.ptr, 1, message.len, c.stderr);
        return 1;
    };
    return 0;
}
