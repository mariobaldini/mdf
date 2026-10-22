//! Compare complete parsed document models across parser migrations.
const std = @import("std");
const mdf = @import("mdf");
const c = mdf.native;

fn snapshot(path: [*:0]const u8) !void {
    const a = std.heap.c_allocator;
    const file = c.fopen(path, "rb") orelse return error.CannotOpenInput;
    defer _ = c.fclose(file);
    if (c.fseek(file, 0, c.SEEK_END) != 0) return error.CannotMeasureInput;
    const length = c.ftell(file);
    if (length < 0 or length > 64 * 1024 * 1024) return error.InvalidInputSize;
    c.rewind(file);
    const input = try a.alloc(u8, @intCast(length));
    defer a.free(input);
    if (c.fread(input.ptr, 1, input.len, file) != input.len) return error.CannotReadInput;
    var doc = try mdf.document.Document.parseDeferred(a, input, std.mem.span(path));
    defer doc.deinit();
    const bytes = try std.json.Stringify.valueAlloc(a, doc.blocks, .{});
    defer a.free(bytes);
    if (c.fwrite(bytes.ptr, 1, bytes.len, c.stdout) != bytes.len) return error.CannotWriteSnapshot;
    if (c.fputc('\n', c.stdout) < 0) return error.CannotWriteSnapshot;
}

pub export fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    if (argc != 2) return 2;
    snapshot(argv[1]) catch |err| {
        const message = @errorName(err);
        _ = c.fwrite(message.ptr, 1, message.len, c.stderr);
        return 1;
    };
    return 0;
}
