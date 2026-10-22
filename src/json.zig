//! C bindings to std.json for the C++ frontend. An arena owns each tree.
//! Views are read-only; the frontend detaches a shared tree before mutation.
const std = @import("std");
const a = std.heap.c_allocator;
const Value = std.json.Value;
const Buffer = extern struct { ptr: ?[*]const u8 = null, len: usize = 0 };
const Tree = struct {
    arena: std.heap.ArenaAllocator,
    value: Value = .null,

    fn create() !*Tree {
        const tree = try a.create(Tree);
        tree.* = .{ .arena = .init(a) };
        return tree;
    }
};

fn copy(allocator: std.mem.Allocator, value: Value, depth: usize) !Value {
    if (depth > 256) return error.JsonNestingTooDeep;
    return switch (value) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .array => |items| blk: {
            var result: std.array_list.Managed(Value) = .init(allocator);
            try result.ensureTotalCapacity(items.items.len);
            for (items.items) |item| result.appendAssumeCapacity(try copy(allocator, item, depth + 1));
            break :blk .{ .array = result };
        },
        .object => |items| blk: {
            var result: std.json.ObjectMap = .empty;
            try result.ensureTotalCapacity(allocator, items.count());
            var it = items.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                result.putAssumeCapacity(key, try copy(allocator, entry.value_ptr.*, depth + 1));
            }
            break :blk .{ .object = result };
        },
        else => value,
    };
}

export fn mdf_json_parse(ptr: [*]const u8, len: usize, err: *Buffer) ?*Tree {
    err.* = .{};
    const tree = Tree.create() catch return null;
    tree.value = std.json.parseFromSliceLeaky(Value, tree.arena.allocator(), ptr[0..len], .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
    }) catch |failure| {
        const name = @errorName(failure);
        err.* = .{ .ptr = name.ptr, .len = name.len };
        mdf_json_destroy(tree);
        return null;
    };
    return tree;
}

export fn mdf_json_clone(value: ?*const Value) ?*Tree {
    const tree = Tree.create() catch return null;
    tree.value = copy(tree.arena.allocator(), if (value) |v| v.* else .null, 0) catch {
        mdf_json_destroy(tree);
        return null;
    };
    return tree;
}

export fn mdf_json_new(kind: u32, bits: u64, number: f64, ptr: ?[*]const u8, len: usize) ?*Tree {
    const tree = Tree.create() catch return null;
    const allocator = tree.arena.allocator();
    tree.value = switch (kind) {
        0 => .null,
        1 => .{ .bool = bits != 0 },
        2 => .{ .integer = @bitCast(bits) },
        3 => if (bits <= std.math.maxInt(i64)) .{ .integer = @intCast(bits) } else blk: {
            const s = std.fmt.allocPrint(allocator, "{d}", .{bits}) catch {
                mdf_json_destroy(tree);
                return null;
            };
            break :blk .{ .number_string = s };
        },
        4 => if (std.math.isFinite(number)) .{ .float = number } else {
            mdf_json_destroy(tree);
            return null;
        },
        5 => .{ .string = allocator.dupe(u8, if (ptr) |p| p[0..len] else "") catch {
            mdf_json_destroy(tree);
            return null;
        } },
        6 => .{ .array = .init(allocator) },
        7 => .{ .object = .empty },
        else => {
            mdf_json_destroy(tree);
            return null;
        },
    };
    return tree;
}

export fn mdf_json_destroy(tree: *Tree) void {
    tree.arena.deinit();
    a.destroy(tree);
}
export fn mdf_json_root(tree: *const Tree) *const Value {
    return &tree.value;
}
export fn mdf_json_kind(value: ?*const Value) u32 {
    return if (value) |v| switch (v.*) {
        .null => 0,
        .bool => 1,
        .integer => 2,
        .number_string => 3,
        .float => 4,
        .string => 5,
        .array => 6,
        .object => 7,
    } else 0;
}
export fn mdf_json_size(value: ?*const Value) usize {
    return if (value) |v| switch (v.*) {
        .array => |items| items.items.len,
        .object => |items| items.count(),
        else => 0,
    } else 0;
}
export fn mdf_json_field(value: ?*const Value, key: [*]const u8, len: usize) ?*const Value {
    const v = value orelse return null;
    return if (v.* == .object) v.object.getPtr(key[0..len]) else null;
}
export fn mdf_json_element(value: ?*const Value, index: usize) ?*const Value {
    const v = value orelse return null;
    return if (v.* == .array and index < v.array.items.len) &v.array.items[index] else null;
}
export fn mdf_json_string(value: ?*const Value) Buffer {
    const v = value orelse return .{};
    return if (v.* == .string) .{ .ptr = v.string.ptr, .len = v.string.len } else .{};
}
export fn mdf_json_boolean(value: ?*const Value, result: *bool) bool {
    const v = value orelse return false;
    if (v.* != .bool) return false;
    result.* = v.bool;
    return true;
}
export fn mdf_json_signed(value: ?*const Value, result: *i64) bool {
    const v = value orelse return false;
    result.* = switch (v.*) {
        .integer => |n| n,
        .number_string => |n| std.fmt.parseInt(i64, n, 10) catch return false,
        else => return false,
    };
    return true;
}
export fn mdf_json_unsigned(value: ?*const Value, result: *u64) bool {
    const v = value orelse return false;
    result.* = switch (v.*) {
        .integer => |n| if (n >= 0) @intCast(n) else return false,
        .number_string => |n| std.fmt.parseInt(u64, n, 10) catch return false,
        else => return false,
    };
    return true;
}
export fn mdf_json_number(value: ?*const Value, result: *f64) bool {
    const v = value orelse return false;
    result.* = switch (v.*) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        .number_string => |n| std.fmt.parseFloat(f64, n) catch return false,
        else => return false,
    };
    return std.math.isFinite(result.*);
}
export fn mdf_json_set(tree: *Tree, key: [*]const u8, len: usize, value: ?*const Value) bool {
    const allocator = tree.arena.allocator();
    if (tree.value == .null) tree.value = .{ .object = .empty };
    if (tree.value != .object) return false;
    const owned = copy(allocator, if (value) |v| v.* else .null, 0) catch return false;
    if (tree.value.object.getPtr(key[0..len])) |slot| {
        slot.* = owned;
    } else {
        const name = allocator.dupe(u8, key[0..len]) catch return false;
        tree.value.object.put(allocator, name, owned) catch return false;
    }
    return true;
}
export fn mdf_json_append(tree: *Tree, value: ?*const Value) bool {
    if (tree.value != .array) return false;
    const owned = copy(tree.arena.allocator(), if (value) |v| v.* else .null, 0) catch return false;
    tree.value.array.append(owned) catch return false;
    return true;
}
export fn mdf_json_replace(tree: *Tree, index: usize, value: ?*const Value) bool {
    if (tree.value != .array or index >= tree.value.array.items.len) return false;
    const owned = copy(tree.arena.allocator(), if (value) |v| v.* else .null, 0) catch return false;
    tree.value.array.items[index] = owned;
    return true;
}
export fn mdf_json_dump(value: ?*const Value) Buffer {
    const bytes = std.json.Stringify.valueAlloc(a, if (value) |v| v.* else .null, .{}) catch return .{};
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}
