//! Read-only system-font discovery and private font resources. Fontconfig is
//! confined to the deferred UI; discovery never changes its current config.
const std = @import("std");
const c = @import("ui_native");
const profile = @import("ui-profile.zig");
const a = std.heap.c_allocator;
const Notify = ?*const fn () callconv(.c) void;
const Set = std.StringHashMapUnmanaged(void);

fn remember(set: *Set, value: []const u8) !bool {
    if (set.contains(value)) return false;
    const owned = try a.dupe(u8, value);
    errdefer a.free(owned);
    try set.put(a, owned, {});
    return true;
}
fn forget(set: *Set) void {
    var keys = set.keyIterator();
    while (keys.next()) |key| a.free(key.*);
    set.deinit(a);
}
fn scalable(font: *c.FcPattern) bool {
    var value: c.FcBool = c.FcFalse;
    return c.FcPatternGetBool(font, c.FC_SCALABLE, 0, &value) == c.FcResultMatch and value != 0;
}
fn fixedWidth(font: *c.FcPattern) bool {
    var spacing: c_int = c.FC_PROPORTIONAL;
    var value: c.FcBool = c.FcFalse;
    var characters: ?*c.FcCharSet = null;
    return c.FcPatternGetInteger(font, c.FC_SPACING, 0, &spacing) == c.FcResultMatch and
        (spacing == c.FC_MONO or spacing == c.FC_DUAL or spacing == c.FC_CHARCELL) and
        c.FcPatternGetBool(font, c.FC_SCALABLE, 0, &value) == c.FcResultMatch and value != 0 and
        c.FcPatternGetCharSet(font, c.FC_CHARSET, 0, &characters) == c.FcResultMatch and
        c.FcCharSetHasChar(characters, 'i') != 0 and c.FcCharSetHasChar(characters, 'W') != 0 and
        c.FcCharSetHasChar(characters, '0') != 0 and c.FcCharSetHasChar(characters, ' ') != 0;
}
fn directories(list: ?*c.FcStrList, output: *std.ArrayList([:0]u8)) !void {
    const strings = list orelse return;
    while (c.FcStrListNext(strings)) |directory| {
        const path = try a.dupeSentinel(u8, std.mem.span(directory), 0);
        errdefer a.free(path);
        try output.append(a, path);
    }
}

pub const Prepared = struct {
    references: std.atomic.Value(u32) = .init(1),
    config: ?*c.FcConfig = null,
    fds: std.ArrayList(c_int) = .empty,
    sources: std.ArrayList([]u8) = .empty,
    family: []u8 = &.{},
    failure: []u8 = &.{},
    bytes: usize = 0,
    mono: bool,
    unresolved: []u32 = &.{},

    fn create(mono: bool) !*Prepared {
        const self = try a.create(Prepared);
        self.* = .{ .mono = mono };
        return self;
    }
    pub fn retain(self: *Prepared) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }
    pub fn destroy(self: *Prepared) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        if (self.config) |config| c.FcConfigDestroy(config);
        for (self.fds.items) |fd| _ = c.close(fd);
        self.fds.deinit(a);
        for (self.sources.items) |source| a.free(source);
        self.sources.deinit(a);
        a.free(self.family);
        a.free(self.failure);
        a.free(self.unresolved);
        a.destroy(self);
    }
};
const Worker = struct {
    mono: bool,
    characters: []u32,
    bundled_fds: []c_int,
    notify: Notify,
    tracing: bool,
    external_stop: ?*const std.atomic.Value(bool) = null,
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    result: ?*Prepared = null,

    fn create(mono: bool, characters: []const u32, fds: []const c_int, notify: Notify, tracing: bool) !*Worker {
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        const glyphs = try a.dupe(u32, characters);
        errdefer a.free(glyphs);
        const files = try a.dupe(c_int, fds);
        errdefer a.free(files);
        self.* = .{ .mono = mono, .characters = glyphs, .bundled_fds = files, .notify = notify, .tracing = tracing };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn destroy(self: *Worker) void {
        self.stop.store(true, .monotonic);
        self.join();
        if (self.result) |result| result.destroy();
        a.free(self.characters);
        a.free(self.bundled_fds);
        a.destroy(self);
    }
    fn join(self: *Worker) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
    fn check(self: *Worker) !void {
        if (self.stop.load(.monotonic) or (if (self.external_stop) |stop| stop.load(.monotonic) else false)) return error.Canceled;
    }
    fn track(self: Worker) u8 {
        return if (self.mono) 2 else 5;
    }
    fn phase(self: Worker, comptime src: std.builtin.SourceLocation, comptime name: []const u8) profile.Span {
        return profile.begin(self.tracing, src, name, self.track());
    }
    fn catalogue(self: *Worker, config: *c.FcConfig) !*c.FcFontSet {
        const timing = self.phase(@src(), "Read system font catalogue without writing caches");
        defer timing.end();
        const fonts = c.FcFontSetCreate() orelse return error.FontCatalogueFailed;
        errdefer c.FcFontSetDestroy(fonts);
        var pending: std.ArrayList([:0]u8) = .empty;
        defer {
            for (pending.items) |path| a.free(path);
            pending.deinit(a);
        }
        const roots = c.FcConfigGetFontDirs(config);
        defer if (roots) |list| c.FcStrListDone(list);
        try directories(roots, &pending);
        const Identity = struct { device: u64, inode: u64 };
        var seen: std.AutoHashMapUnmanaged(Identity, void) = .empty;
        defer seen.deinit(a);
        var at: usize = 0;
        while (at < pending.items.len) : (at += 1) {
            try self.check();
            const directory = pending.items[at];
            var info: c.struct_stat = undefined;
            if (c.stat(directory, &info) != 0 or info.st_mode & c.S_IFMT != c.S_IFDIR) continue;
            const entry = try seen.getOrPut(a, .{ .device = @intCast(info.st_dev), .inode = @intCast(info.st_ino) });
            if (entry.found_existing) continue;
            const cache = c.FcDirCacheLoad(directory, config, null);
            defer if (cache) |value| c.FcDirCacheUnload(value);
            const found: *c.FcFontSet = block: {
                if (cache) |value| {
                    var index: c_int = 0;
                    while (index < c.FcCacheNumSubdir(value)) : (index += 1) {
                        const path = try a.dupeSentinel(u8, std.mem.span(c.FcCacheSubdir(value, index)), 0);
                        errdefer a.free(path);
                        try pending.append(a, path);
                    }
                    break :block c.FcCacheCopySet(value);
                }
                const scanned = c.FcFontSetCreate() orelse return error.FontScanFailed;
                errdefer c.FcFontSetDestroy(scanned);
                const subdirs = c.FcStrSetCreate() orelse return error.FontScanFailed;
                defer c.FcStrSetDestroy(subdirs);
                _ = c.FcDirScan(scanned, subdirs, null, null, directory, c.FcTrue);
                const children = c.FcStrListCreate(subdirs);
                defer if (children) |list| c.FcStrListDone(list);
                try directories(children, &pending);
                break :block scanned;
            } orelse continue;
            defer c.FcFontSetDestroy(found);
            var index: usize = 0;
            while (index < found.nfont) : (index += 1) {
                const font = found.fonts[index] orelse continue;
                if (if (self.mono) fixedWidth(font) else scalable(font)) {
                    c.FcPatternReference(font);
                    if (c.FcFontSetAdd(fonts, font) == 0) {
                        c.FcPatternDestroy(font);
                        return error.FontMetadataFailed;
                    }
                }
            }
        }
        return fonts;
    }
    fn loadFile(self: *Worker, prepared: *Prepared, path: [*:0]const u8) !void {
        const timing = self.phase(@src(), "Load selected system font into anonymous memory");
        defer timing.end();
        const source = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
        if (source < 0) return error.FontReadFailed;
        defer _ = c.close(source);
        var status: c.struct_stat = undefined;
        if (c.fstat(source, &status) != 0 or status.st_size <= 0 or status.st_size > 128 * 1024 * 1024) return error.InvalidFontSize;
        const name: [:0]const u8 = if (self.mono) "mdf-mono-font" else "mdf-sans-font";
        const fd = c.memfd_create(name, c.MFD_CLOEXEC);
        if (fd < 0) return error.FontMemoryFailed;
        prepared.fds.append(a, fd) catch |err| {
            _ = c.close(fd);
            return err;
        };
        var buffer: [65536]u8 = undefined;
        while (true) {
            try self.check();
            const length = c.read(source, &buffer, buffer.len);
            if (length < 0 and c.__errno_location().* == c.EINTR) continue;
            if (length < 0) return error.FontReadFailed;
            if (length == 0) break;
            var offset: usize = 0;
            while (offset < length) {
                const count = c.write(fd, buffer[offset..].ptr, @as(usize, @intCast(length)) - offset);
                if (count < 0 and c.__errno_location().* == c.EINTR) continue;
                if (count <= 0) return error.FontMemoryFailed;
                offset += @intCast(count);
            }
            prepared.bytes += @intCast(length);
        }
        try self.check();
        {
            const registering = self.phase(@src(), "Register selected system font metadata");
            defer registering.end();
            try register(prepared.config.?, fd);
        }
        const owned = try a.dupe(u8, std.mem.span(path));
        errdefer a.free(owned);
        try prepared.sources.append(a, owned);
    }
    fn prepare(self: *Worker) !*Prepared {
        const lookup = c.FcConfigCreate() orelse return error.FontLookupFailed;
        defer c.FcConfigDestroy(lookup);
        {
            const timing = if (self.mono) self.phase(@src(), "Read system Fontconfig configuration") else self.phase(@src(), "Read fallback Fontconfig configuration");
            defer timing.end();
            if (c.FcConfigParseAndLoad(lookup, null, c.FcTrue) == 0) return error.FontConfigurationUnavailable;
            _ = c.FcConfigSetRescanInterval(lookup, 0);
        }
        const fonts = try self.catalogue(lookup);
        defer c.FcFontSetDestroy(fonts);
        try self.check();
        if (self.mono and fonts.nfont == 0) return error.NoMonospaceFonts;
        const prepared = try Prepared.create(self.mono);
        errdefer prepared.destroy();
        prepared.config = c.FcConfigCreate() orelse return error.PrivateFontConfigurationFailed;
        _ = c.FcConfigSetRescanInterval(prepared.config, 0);
        if (self.mono) try self.prepareMono(prepared, lookup, fonts) else try self.prepareFallback(prepared, lookup, fonts);
        return prepared;
    }
    fn prepareMono(self: *Worker, prepared: *Prepared, lookup: *c.FcConfig, fonts: *c.FcFontSet) !void {
        var loaded: Set = .empty;
        defer forget(&loaded);
        for (0..4) |style| {
            try self.check();
            const timing = self.phase(@src(), "Match system monospace style");
            defer timing.end();
            const font = try match(lookup, fonts, if (style == 0) "monospace" else prepared.family, @intCast(style), true, null);
            defer if (font) |value| c.FcPatternDestroy(value);
            var family: [*c]c.FcChar8 = null;
            var path: [*c]c.FcChar8 = null;
            if (font == null or !fixedWidth(font.?) or
                c.FcPatternGetString(font, c.FC_FAMILY, 0, &family) != c.FcResultMatch or
                c.FcPatternGetString(font, c.FC_FILE, 0, &path) != c.FcResultMatch) return error.NoMatchingMonospaceFont;
            if (style == 0) prepared.family = try a.dupe(u8, std.mem.span(family));
            if (try remember(&loaded, std.mem.span(path))) try self.loadFile(prepared, @ptrCast(path));
        }
    }
    fn prepareFallback(self: *Worker, prepared: *Prepared, lookup: *c.FcConfig, fonts: *c.FcFontSet) !void {
        var remaining = c.FcCharSetCreate() orelse return error.FontCharsetFailed;
        defer c.FcCharSetDestroy(remaining);
        for (self.characters) |ch| _ = c.FcCharSetAddChar(remaining, ch);
        const request = try query(lookup, "sans-serif", 0, false, remaining);
        defer c.FcPatternDestroy(request);
        var status: c.FcResult = undefined;
        var set: ?*c.FcFontSet = fonts;
        const sorted = c.FcFontSetSort(lookup, &set, 1, request, c.FcTrue, null, &status);
        defer if (sorted) |value| c.FcFontSetDestroy(value);
        var loaded: Set = .empty;
        defer forget(&loaded);
        var families: Set = .empty;
        defer forget(&families);
        var family_names: std.ArrayList(u8) = .empty;
        defer family_names.deinit(a);
        if (sorted) |pointer| {
            const found: *c.FcFontSet = pointer;
            var index: usize = 0;
            while (index < found.nfont and c.FcCharSetCount(remaining) != 0) : (index += 1) {
                try self.check();
                const font = found.fonts[index] orelse continue;
                var coverage: ?*c.FcCharSet = null;
                var family: [*c]c.FcChar8 = null;
                var path: [*c]c.FcChar8 = null;
                if (c.FcPatternGetCharSet(font, c.FC_CHARSET, 0, &coverage) != c.FcResultMatch or
                    c.FcCharSetIntersectCount(coverage, remaining) == 0 or
                    c.FcPatternGetString(font, c.FC_FAMILY, 0, &family) != c.FcResultMatch or
                    c.FcPatternGetString(font, c.FC_FILE, 0, &path) != c.FcResultMatch) continue;
                const needed = c.FcCharSetIntersect(coverage, remaining) orelse return error.FontCharsetFailed;
                defer c.FcCharSetDestroy(needed);
                const selected = std.mem.span(family);
                if (try remember(&families, selected)) {
                    if (family_names.items.len > 0) try family_names.appendSlice(a, ", ");
                    try family_names.appendSlice(a, selected);
                }
                if (try remember(&loaded, std.mem.span(path))) try self.loadFile(prepared, @ptrCast(path));
                for (1..4) |style| {
                    try self.check();
                    const styled = try match(lookup, fonts, selected, @intCast(style), false, needed);
                    defer if (styled) |value| c.FcPatternDestroy(value);
                    var styled_coverage: ?*c.FcCharSet = null;
                    var styled_family: [*c]c.FcChar8 = null;
                    var styled_file: [*c]c.FcChar8 = null;
                    if (styled != null and c.FcPatternGetCharSet(styled, c.FC_CHARSET, 0, &styled_coverage) == c.FcResultMatch and
                        c.FcCharSetIsSubset(needed, styled_coverage) != 0 and
                        c.FcPatternGetString(styled, c.FC_FAMILY, 0, &styled_family) == c.FcResultMatch and
                        std.mem.eql(u8, selected, std.mem.span(styled_family)) and
                        c.FcPatternGetString(styled, c.FC_FILE, 0, &styled_file) == c.FcResultMatch and
                        try remember(&loaded, std.mem.span(styled_file)))
                        try self.loadFile(prepared, @ptrCast(styled_file));
                }
                const reduced = c.FcCharSetSubtract(remaining, coverage) orelse return error.FontCharsetFailed;
                c.FcCharSetDestroy(remaining);
                remaining = reduced;
            }
        }
        try self.check();
        var unresolved: std.ArrayList(u32) = .empty;
        defer unresolved.deinit(a);
        for (self.characters) |ch| if (c.FcCharSetHasChar(remaining, ch) != 0) try unresolved.append(a, ch);
        prepared.unresolved = try unresolved.toOwnedSlice(a);
        prepared.family = try family_names.toOwnedSlice(a);
        if (prepared.sources.items.len == 0) {
            prepared.failure = try a.dupe(u8, "No installed font covers the missing document characters");
            return;
        }
        for (self.bundled_fds) |source| {
            const fd = c.fcntl(source, c.F_DUPFD_CLOEXEC, @as(c_int, 0));
            if (fd < 0) return error.BundledFontRetainFailed;
            prepared.fds.append(a, fd) catch |err| {
                _ = c.close(fd);
                return err;
            };
            try register(prepared.config.?, fd);
        }
    }
    fn run(self: *Worker) void {
        const name: [:0]const u8 = if (self.mono) "mdf-monospace" else "mdf-fallback";
        _ = c.prctl(c.PR_SET_NAME, name.ptr, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
        {
            const timing = if (self.mono) self.phase(@src(), "Prepare deferred system monospace") else self.phase(@src(), "Prepare deferred system Sans fallback");
            defer timing.end();
            self.result = self.prepare() catch |err| failure: {
                if (err == error.Canceled) return;
                const result = Prepared.create(self.mono) catch break :failure null;
                result.failure = a.dupe(u8, @errorName(err)) catch &.{};
                if (!self.mono) result.unresolved = a.dupe(u32, self.characters) catch &.{};
                break :failure result;
            };
        }
        if (self.stop.load(.monotonic)) return;
        if (self.mono) profile.signal(self.tracing, @src(), "System monospace prepared", 2) else profile.signal(self.tracing, @src(), "System Sans fallback prepared", 5);
        self.done.store(true, .release);
        if (self.notify) |notify| notify();
    }
};
/// Run discovery on an already-owned worker thread. This permits preparing a
/// text map before publication without a second worker or premature readiness.
pub fn prepareInline(mono: bool, characters: []const u32, bundled_fds: []const c_int,
    tracing: bool, stop: *const std.atomic.Value(bool)) !*Prepared
{
    var worker = Worker{ .mono = mono, .characters = @constCast(characters), .bundled_fds = @constCast(bundled_fds),
        .notify = null, .tracing = tracing, .external_stop = stop };
    return worker.prepare();
}
fn query(config: *c.FcConfig, family: []const u8, style: u32, mono: bool, characters: ?*const c.FcCharSet) !*c.FcPattern {
    const request = c.FcPatternCreate() orelse return error.FontRequestFailed;
    errdefer c.FcPatternDestroy(request);
    const name = try a.dupeSentinel(u8, family, 0);
    defer a.free(name);
    if (c.FcPatternAddString(request, c.FC_FAMILY, name) == 0 or
        c.FcPatternAddBool(request, c.FC_SCALABLE, c.FcTrue) == 0 or
        c.FcPatternAddInteger(request, c.FC_WEIGHT, if (style & 1 != 0) c.FC_WEIGHT_BOLD else c.FC_WEIGHT_REGULAR) == 0 or
        c.FcPatternAddInteger(request, c.FC_SLANT, if (style & 2 != 0) c.FC_SLANT_ITALIC else c.FC_SLANT_ROMAN) == 0) return error.FontRequestFailed;
    if (mono and c.FcPatternAddInteger(request, c.FC_SPACING, c.FC_MONO) == 0) return error.FontRequestFailed;
    if (characters != null and c.FcPatternAddCharSet(request, c.FC_CHARSET, characters) == 0) return error.FontRequestFailed;
    _ = c.FcConfigSubstitute(config, request, c.FcMatchPattern);
    c.FcDefaultSubstitute(request);
    return request;
}
fn match(config: *c.FcConfig, fonts: *c.FcFontSet, family: []const u8, style: u32, mono: bool, characters: ?*const c.FcCharSet) !?*c.FcPattern {
    const request = try query(config, family, style, mono, characters);
    defer c.FcPatternDestroy(request);
    var set: ?*c.FcFontSet = fonts;
    var status: c.FcResult = undefined;
    return c.FcFontSetMatch(config, &set, 1, request, &status);
}
fn register(config: *c.FcConfig, fd: c_int) !void {
    var path: [64]u8 = undefined;
    const filename = try std.fmt.bufPrint(&path, "/proc/self/fd/{d}\x00", .{fd});
    if (c.FcConfigAppFontAddFile(config, filename.ptr) == 0) return error.FontRegistrationFailed;
}

export fn mdf_font_worker_create(mono: c_int, characters: ?[*]const u32, count: usize, fds: ?[*]const c_int, fd_count: usize, notify: Notify, tracing: c_int) ?*Worker {
    if (count > 0x110000 or fd_count > 256 or (count != 0 and characters == null) or (fd_count != 0 and fds == null)) return null;
    return Worker.create(mono != 0, if (characters) |ptr| ptr[0..count] else &.{},
        if (fds) |ptr| ptr[0..fd_count] else &.{}, notify, tracing != 0) catch null;
}
export fn mdf_font_worker_destroy(self: ?*Worker) void {
    if (self) |worker| worker.destroy();
}
export fn mdf_font_worker_complete(self: *Worker) c_int {
    return @intFromBool(self.done.load(.acquire));
}
export fn mdf_font_worker_take(self: *Worker) ?*Prepared {
    if (!self.done.load(.acquire)) return null;
    self.join();
    const result = self.result;
    self.result = null;
    return result;
}
fn bytes(value: []const u8) c.struct_MdfFontBytes {
    return .{ .data = value.ptr, .length = value.len };
}
export fn mdf_font_prepared_view(self: *Prepared) c.struct_MdfPreparedFontView {
    return .{ .config = self.config, .fds = self.fds.items.ptr, .fd_count = self.fds.items.len,
        .source_count = self.sources.items.len, .family = bytes(self.family), .@"error" = bytes(self.failure),
        .bytes = self.bytes, .monospace = @intFromBool(self.mono), .unresolved = self.unresolved.ptr,
        .unresolved_count = self.unresolved.len };
}
export fn mdf_font_prepared_source(self: *Prepared, index: usize) c.struct_MdfFontBytes {
    return bytes(if (index < self.sources.items.len) self.sources.items[index] else "");
}
export fn mdf_font_prepared_destroy(self: ?*Prepared) void {
    if (self) |prepared| prepared.destroy();
}
