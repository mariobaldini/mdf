//! Exercise the actual exported ABI, including opaque ownership and lengths.
const std = @import("std");
const Buffer = @import("mdf").core.Buffer;
const Tree = opaque {};
const Value = opaque {};
extern fn mdf_json_parse([*]const u8, usize, *Buffer) ?*Tree;
extern fn mdf_json_clone(?*const Value) ?*Tree;
extern fn mdf_json_new(u32, u64, f64, ?[*]const u8, usize) ?*Tree;
extern fn mdf_json_destroy(*Tree) void;
extern fn mdf_json_root(*const Tree) *const Value;
extern fn mdf_json_kind(?*const Value) u32;
extern fn mdf_json_size(?*const Value) usize;
extern fn mdf_json_field(?*const Value, [*]const u8, usize) ?*const Value;
extern fn mdf_json_element(?*const Value, usize) ?*const Value;
extern fn mdf_json_string(?*const Value) Buffer;
extern fn mdf_json_boolean(?*const Value, *bool) bool;
extern fn mdf_json_signed(?*const Value, *i64) bool;
extern fn mdf_json_unsigned(?*const Value, *u64) bool;
extern fn mdf_json_number(?*const Value, *f64) bool;
extern fn mdf_json_set(*Tree, [*]const u8, usize, ?*const Value) bool;
extern fn mdf_json_append(*Tree, ?*const Value) bool;
extern fn mdf_json_replace(*Tree, usize, ?*const Value) bool;
extern fn mdf_json_dump(?*const Value) Buffer;
extern fn mdf_buffer_free(Buffer) void;

fn parse(input: []const u8) !*Tree {
    var err: Buffer = .{};
    return mdf_json_parse(input.ptr, input.len, &err) orelse error.InvalidJson;
}
fn field(value: *const Value, name: []const u8) ?*const Value {
    return mdf_json_field(value, name.ptr, name.len);
}
fn string(value: ?*const Value) []const u8 {
    const b = mdf_json_string(value);
    return if (b.ptr) |p| p[0..b.len] else "";
}

test "json ABI: absent values are safe and never claim a scalar conversion" {
    var number: i64 = 77;
    var boolean = true;
    try std.testing.expectEqual(@as(u32, 0), mdf_json_kind(null));
    try std.testing.expectEqual(@as(usize, 0), mdf_json_size(null));
    try std.testing.expect(mdf_json_element(null, 0) == null);
    try std.testing.expect(!mdf_json_signed(null, &number) and !mdf_json_boolean(null, &boolean));
    try std.testing.expectEqual(@as(i64, 77), number);
    try std.testing.expect(boolean);
}
test "json ABI: parsing owns unescaped strings after the input is overwritten" {
    const bytes = try std.testing.allocator.dupe(u8, "{\"name\":\"owned\"}");
    defer std.testing.allocator.free(bytes);
    const tree = try parse(bytes);
    defer mdf_json_destroy(tree);
    @memset(bytes, 'x');
    try std.testing.expectEqualStrings("owned", string(field(mdf_json_root(tree), "name")));
}
test "json ABI: signed and unsigned 64-bit extrema remain exact" {
    const tree = try parse("{\"lo\":-9223372036854775808,\"hi\":18446744073709551615}");
    defer mdf_json_destroy(tree);
    var lo: i64 = 0;
    var hi: u64 = 0;
    try std.testing.expect(mdf_json_signed(field(mdf_json_root(tree), "lo"), &lo));
    try std.testing.expect(mdf_json_unsigned(field(mdf_json_root(tree), "hi"), &hi));
    try std.testing.expectEqual(std.math.minInt(i64), lo);
    try std.testing.expectEqual(std.math.maxInt(u64), hi);
    try std.testing.expect(!mdf_json_signed(field(mdf_json_root(tree), "hi"), &lo));
    try std.testing.expect(!mdf_json_unsigned(field(mdf_json_root(tree), "lo"), &hi));
}
test "json ABI: duplicate fields keep the final value" {
    const tree = try parse("{\"a\":1,\"a\":2}");
    defer mdf_json_destroy(tree);
    var result: i64 = 0;
    try std.testing.expect(mdf_json_signed(field(mdf_json_root(tree), "a"), &result));
    try std.testing.expectEqual(@as(i64, 2), result);
}
test "json ABI: cloning a nested value does not borrow its original arena" {
    const tree = try parse("{\"child\":{\"text\":\"retained\"}}");
    const clone = mdf_json_clone(field(mdf_json_root(tree), "child")) orelse {
        mdf_json_destroy(tree);
        return error.CloneFailed;
    };
    defer mdf_json_destroy(clone);
    mdf_json_destroy(tree);
    try std.testing.expectEqualStrings("retained", string(field(mdf_json_root(clone), "text")));
}
test "json ABI: insertion copies foreign values before their owner is destroyed" {
    const target = try parse("{}");
    defer mdf_json_destroy(target);
    const source = try parse("{\"payload\":[\"one\",\"two\"]}");
    const inserted = mdf_json_set(target, "copy", 4, field(mdf_json_root(source), "payload"));
    mdf_json_destroy(source);
    try std.testing.expect(inserted);
    const copied = field(mdf_json_root(target), "copy");
    try std.testing.expectEqual(@as(usize, 2), mdf_json_size(copied));
    try std.testing.expectEqualStrings("two", string(mdf_json_element(copied, 1)));
}
test "json ABI: embedded NUL in an object key uses the explicit byte length" {
    const tree = try parse("{\"a\\u0000b\":true}");
    defer mdf_json_destroy(tree);
    var result = false;
    try std.testing.expect(mdf_json_boolean(field(mdf_json_root(tree), "a\x00b"), &result) and result);
    try std.testing.expect(field(mdf_json_root(tree), "a") == null);
}
test "json ABI: invalid JSON reports an error without returning a tree" {
    for ([_][]const u8{ "{", "[1,]", "{\"x\":NaN}", "true false", "\"\\uD800\"" }) |input| {
        var err: Buffer = .{};
        const tree = mdf_json_parse(input.ptr, input.len, &err);
        if (tree) |unexpected| {
            mdf_json_destroy(unexpected);
            return error.AcceptedInvalidJson;
        }
        try std.testing.expect(err.ptr != null and err.len > 0);
    }
}
test "json ABI: array replacement respects bounds and container types" {
    const array = try parse("[1]");
    defer mdf_json_destroy(array);
    try std.testing.expect(!mdf_json_replace(array, 1, null));
    try std.testing.expect(!mdf_json_set(array, "x", 1, null));
    try std.testing.expect(mdf_json_append(array, null));
    try std.testing.expect(mdf_json_replace(array, 0, null));
    try std.testing.expectEqual(@as(usize, 2), mdf_json_size(mdf_json_root(array)));
    try std.testing.expectEqual(@as(u32, 0), mdf_json_kind(mdf_json_element(mdf_json_root(array), 0)));
}
test "json ABI: nonfinite numbers and invalid construction tags are rejected" {
    try std.testing.expect(mdf_json_new(4, 0, std.math.inf(f64), null, 0) == null);
    try std.testing.expect(mdf_json_new(4, 0, std.math.nan(f64), null, 0) == null);
    try std.testing.expect(mdf_json_new(99, 0, 0, null, 0) == null);
    const tree = try parse("1e9999");
    defer mdf_json_destroy(tree);
    var number: f64 = 0;
    try std.testing.expect(!mdf_json_number(mdf_json_root(tree), &number));
}
test "json ABI: serialization preserves large integers for an independent typed reader" {
    const tree = try parse("{\"n\":18446744073709551615,\"text\":\"quote\\\" \\u4E2D\"}");
    defer mdf_json_destroy(tree);
    const bytes = mdf_json_dump(mdf_json_root(tree));
    defer mdf_buffer_free(bytes);
    const parsed = try std.json.parseFromSlice(struct { n: u64, text: []const u8 }, std.testing.allocator, bytes.ptr.?[0..bytes.len], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), parsed.value.n);
    try std.testing.expectEqualStrings("quote\" 中", parsed.value.text);
}
