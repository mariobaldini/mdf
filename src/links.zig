const std = @import("std");

pub const Link = union(enum) { web: []const u8, local: []const u8, fragment: []const u8 };

pub fn resolve(a: std.mem.Allocator, current_path: []const u8, url: []const u8) !Link {
    if (std.mem.indexOfAny(u8, url, "\r\n\x00") != null) return error.InvalidLink;
    if (std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "mailto:"))
        return .{ .web = try a.dupe(u8, url) };
    if (std.mem.startsWith(u8, url, "#")) return .{ .fragment = try decode(a, url[1..]) };
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const raw = url[0..end];
    if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, ':') != null or std.mem.startsWith(u8, raw, "//")) return error.UnsupportedLink;
    const decoded = try decode(a, raw);
    defer a.free(decoded);
    const extension = std.fs.path.extension(decoded);
    if (!std.ascii.eqlIgnoreCase(extension, ".md") and !std.ascii.eqlIgnoreCase(extension, ".markdown") and !std.ascii.eqlIgnoreCase(extension, ".txt")) return error.UnsupportedLink;
    return .{ .local = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(current_path) orelse ".", decoded }) };
}

pub fn decode(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(a);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '%') {
            if (i + 2 >= raw.len) return error.InvalidLink;
            const byte = std.fmt.parseInt(u8, raw[i + 1 ..][0..2], 16) catch return error.InvalidLink;
            if (byte == 0) return error.InvalidLink;
            try decoded.append(a, byte);
            i += 2;
        } else try decoded.append(a, raw[i]);
    }
    if (!std.unicode.utf8ValidateSlice(decoded.items)) return error.InvalidLink;
    if (std.mem.indexOfScalar(u8, decoded.items, 0) != null) return error.InvalidLink;
    return decoded.toOwnedSlice(a);
}
pub fn droppedPath(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var lines=std.mem.splitScalar(u8,text,'\n');
    while(lines.next()) |raw| {
        const line=std.mem.trim(u8,raw,"\r");
        if(line.len==0 or line[0]=='#') continue;
        if(!std.ascii.startsWithIgnoreCase(line,"file://")) return error.UnsupportedDrop;
        const rest=line[7..];
        const start=std.mem.indexOfScalar(u8,rest,'/') orelse return error.InvalidDropPath;
        const host=rest[0..start];
        if(host.len>0 and !std.ascii.eqlIgnoreCase(host,"localhost")) return error.RemoteFileDrop;
        const path=try decode(a,rest[start..]);
        errdefer a.free(path);
        if(!std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8,path,"\r\n")!=null) return error.InvalidDropPath;
        return path;
    }
    return error.EmptyDrop;
}

test "relative Markdown links are decoded without shell interpretation" {
    const a = std.testing.allocator;
    const link = try resolve(a, "/tmp/docs/readme.md", "../other/a%20b.md#example");
    defer a.free(link.local);
    try std.testing.expectEqualStrings("/tmp/other/a b.md", link.local);
    try std.testing.expectError(error.UnsupportedLink, resolve(a, "/tmp/readme.md", "javascript:alert(1)"));
    try std.testing.expectError(error.InvalidLink, resolve(a, "/tmp/readme.md", "a%00.md"));
}

test "mail and UTF-8 fragments resolve while invalid bytes are rejected" {
    const a = std.testing.allocator;
    const mail = try resolve(a, "", "mailto:reader@example.com");
    defer a.free(mail.web);
    try std.testing.expectEqualStrings("mailto:reader@example.com", mail.web);
    const fragment = try resolve(a, "", "#caf%C3%A9-time");
    defer a.free(fragment.fragment);
    try std.testing.expectEqualStrings("café-time", fragment.fragment);
    try std.testing.expectError(error.InvalidLink, resolve(a, "", "#bad%00id"));
    try std.testing.expectError(error.InvalidLink, resolve(a, "", "https://example.com\n"));
}
