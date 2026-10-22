//! Optional renderer ownership, ELF validation and anonymous-module loading.
//! No renderer is read or linked until the existing first-viewport gate opens.
const std = @import("std");
const c = @import("native");
const compression = @import("compression.zig");
const profiling = @import("profiling.zig");
const a = std.heap.c_allocator;
pub const Kind = enum(u32) { mermaid = 1, svg = 2, text = 3, image = 4 };
const Api = c.struct_MdfDiagramApi;
const header_size = 40;
const max_module = 256 * 1024 * 1024;

const File = struct {
    fd: c_int,
    size: u64,
    cancel: compression.Cancel,

    fn read(self: File, output: []u8, offset: u64) !void {
        if (offset > self.size or output.len > self.size - offset) return error.TruncatedModule;
        var at: usize = 0;
        while (at < output.len) {
            try canceled(self.cancel);
            const count = c.pread(self.fd, output.ptr + at, @min(65536, output.len - at), @intCast(offset + at));
            if (count < 0 and c.__errno_location().* == c.EINTR) continue;
            if (count <= 0) return error.ModuleReadFailed;
            at += @intCast(count);
        }
    }
    fn value(self: File, comptime T: type, offset: u64) !T {
        var result: T = undefined;
        try self.read(std.mem.asBytes(&result), offset);
        return result;
    }
    fn copyVerified(self: File, output: []u8, offset: u64, checksum: u32) !void {
        var crc: std.hash.Crc32 = .init();
        var at: usize = 0;
        while (at < output.len) {
            const chunk = output[at..@min(at + 65536, output.len)];
            try self.read(chunk, offset + at);
            crc.update(chunk);
            at += chunk.len;
        }
        try canceled(self.cancel);
        if (crc.final() != checksum) return error.CorruptRawModule;
    }
};
pub const Payload = struct {
    data: []u8,
    expanded: usize,
    checksum: u32,
    raw: bool,
};
pub const Header = struct { stored: usize, expanded: usize, checksum: u32, raw: bool };
const Location = struct { offset: u64, header: Header };

fn canceled(cancel: compression.Cancel) !void {
    if (cancel.check) |check| if (check(cancel.context) != 0) return error.Canceled;
}

pub fn parseHeader(header: []const u8, payload_size: u64) !Header {
    if (header.len != header_size or !std.mem.eql(u8, header[0..8], "MDFDG01\x00") or
        std.mem.readInt(u32, header[8..12], .little) != c.MDF_MODULE_CONTAINER_ABI or
        std.mem.readInt(u32, header[12..16], .little) != header_size or
        std.mem.readInt(u32, header[36..40], .little) & ~@as(u32, c.MDF_MODULE_PAYLOAD_RAW) != 0) return error.UnsupportedModuleVersion;
    const stored = std.mem.readInt(u64, header[16..24], .little);
    const expanded = std.mem.readInt(u64, header[24..32], .little);
    const raw = std.mem.readInt(u32, header[36..40], .little) & c.MDF_MODULE_PAYLOAD_RAW != 0;
    if (stored == 0 or stored > max_module or expanded == 0 or expanded > max_module or
        payload_size < header_size or stored != payload_size - header_size or (raw and stored != expanded)) return error.InvalidModuleSize;
    return .{ .stored = @intCast(stored), .expanded = @intCast(expanded), .checksum = std.mem.readInt(u32, header[32..36], .little), .raw = raw };
}

fn locatePayload(fd: c_int, file_size: u64, kind: Kind, cancel: compression.Cancel) !Location {
    const file = File{ .fd = fd, .size = file_size, .cancel = cancel };
    const elf = try file.value(c.Elf64_Ehdr, 0);
    if (!std.mem.eql(u8, elf.e_ident[0..4], "\x7fELF") or elf.e_ident[c.EI_CLASS] != c.ELFCLASS64 or
        elf.e_ident[c.EI_DATA] != c.ELFDATA2LSB or elf.e_shentsize != @sizeOf(c.Elf64_Shdr) or
        elf.e_shnum == 0 or elf.e_shnum > 4096 or elf.e_shstrndx >= elf.e_shnum) return error.InvalidElfMetadata;
    const sections = try a.alloc(c.Elf64_Shdr, elf.e_shnum);
    defer a.free(sections);
    try file.read(std.mem.sliceAsBytes(sections), elf.e_shoff);
    const names = sections[elf.e_shstrndx];
    if (names.sh_size == 0 or names.sh_size > 1024 * 1024) return error.InvalidSectionNames;
    const strings = try a.alloc(u8, @intCast(names.sh_size));
    defer a.free(strings);
    try file.read(strings, names.sh_offset);
    const name: []const u8 = switch (kind) { .svg => ".mdf_svg\x00", .mermaid => ".mdf_mermaid\x00", .text => ".mdf_text\x00", .image => ".mdf_image\x00" };
    var payload: ?c.Elf64_Shdr = null;
    for (sections) |section| {
        if (section.sh_name > strings.len or name.len > strings.len - section.sh_name or
            !std.mem.eql(u8, strings[section.sh_name..][0..name.len], name)) continue;
        if (payload != null) return error.DuplicateModuleSection;
        payload = section;
    }
    const section = payload orelse return error.MissingModuleSection;
    if (section.sh_type != c.SHT_PROGBITS or section.sh_flags & c.SHF_ALLOC != 0 or
        section.sh_size < header_size or section.sh_offset > file.size or
        section.sh_size > file.size - section.sh_offset) return error.MissingModuleSection;
    var header: [header_size]u8 = undefined;
    try file.read(&header, section.sh_offset);
    const info = try parseHeader(&header, section.sh_size);
    return .{ .offset = section.sh_offset + header_size, .header = info };
}

pub fn readPayload(fd: c_int, file_size: u64, kind: Kind, cancel: compression.Cancel) !Payload {
    const location = try locatePayload(fd, file_size, kind, cancel);
    const data = try a.alloc(u8, location.header.stored);
    errdefer a.free(data);
    try (File{ .fd = fd, .size = file_size, .cancel = cancel }).read(data, location.offset);
    return .{ .data = data, .expanded = location.header.expanded, .checksum = location.header.checksum, .raw = location.header.raw };
}

const Module = struct {
    // 0: untouched/retryable cancellation, 1: loader owns it, 2: ready, 3: error.
    state: std.atomic.Value(u32) = .init(0),
    api: ?*const anyopaque = null,
    handle: ?*anyopaque = null,
    fd: c_int = -1,
    ready_ns: u64 = 0,
    stored: u64 = 0,
    expanded: u64 = 0,
    raw: bool = false,
    failure: [512]u8 = @splat(0),

    fn prepare(self: *Module, kind: Kind, cancel: compression.Cancel, provider: c.MdfBuiltinFont,
        text_host: ?*const c.struct_MdfTextHost, depth: usize, track: profiling.Track) !void {
        const total = if (kind == .svg)
            profiling.beginExternal(@src(), "Prepare bundled SVG module", track, depth)
        else if (kind == .text)
            profiling.beginExternal(@src(), "Prepare deferred system text module", track, depth)
        else if (kind == .image)
            profiling.beginExternal(@src(), "Prepare bundled image codec module", track, depth)
        else
            profiling.beginExternal(@src(), "Prepare bundled Mermaid module", track, depth);
        defer total.end();
        const source = c.open("/proc/self/exe", c.O_RDONLY | c.O_CLOEXEC);
        if (source < 0) return error.ModuleInspectionFailed;
        defer _ = c.close(source);
        var stat: c.struct_stat = undefined;
        if (c.fstat(source, &stat) != 0 or stat.st_size < @sizeOf(c.Elf64_Ehdr)) return error.ModuleInspectionFailed;
        const file = File{ .fd = source, .size = @intCast(stat.st_size), .cancel = cancel };
        const location = block: {
            const phase = if (kind == .image) profiling.beginExternal(@src(), "Inspect embedded image codec module", track, depth + 1)
                else if (kind == .text) profiling.beginExternal(@src(), "Inspect embedded system text module", track, depth + 1)
                else profiling.beginExternal(@src(), "Inspect embedded diagram renderer", track, depth + 1);
            defer phase.end();
            break :block try locatePayload(source, file.size, kind, cancel);
        };
        const info = location.header;
        const fd = block: {
            const phase = if (kind == .image) profiling.beginExternal(@src(), "Prepare anonymous image codec memory", track, depth + 1)
                else if (kind == .text) profiling.beginExternal(@src(), "Prepare anonymous system text memory", track, depth + 1)
                else profiling.beginExternal(@src(), "Prepare anonymous diagram module memory", track, depth + 1);
            defer phase.end();
            const flags: c_uint = c.MFD_CLOEXEC | c.MFD_ALLOW_SEALING;
            const name: [:0]const u8 = switch (kind) { .svg => "mdf-svg", .mermaid => "mdf-mermaid", .text => "mdf-system-text", .image => "mdf-image" };
            var fd = c.memfd_create(name, flags | 0x0010); // Linux MFD_EXEC; older kernels reject it.
            if (fd < 0 and c.__errno_location().* == c.EINVAL) fd = c.memfd_create(name, flags);
            if (fd < 0) return error.ModuleMemoryFailed;
            errdefer _ = c.close(fd);
            if (c.ftruncate(fd, @intCast(info.expanded)) != 0) return error.ModuleMemoryFailed;
            break :block fd;
        };
        errdefer _ = c.close(fd);
        {
            const phase = if (kind == .image and info.raw) profiling.beginExternal(@src(), "Read and verify raw image codec", track, depth + 1)
                else if (kind == .image) profiling.beginExternal(@src(), "Decompress image codec module", track, depth + 1)
                else if (info.raw) profiling.beginExternal(@src(), "Read and verify raw diagram renderer", track, depth + 1)
                else if (kind == .text) profiling.beginExternal(@src(), "Decompress system text module", track, depth + 1)
                else profiling.beginExternal(@src(), "Decompress diagram renderer", track, depth + 1);
            defer phase.end();
            const mapped = c.mmap(null, info.expanded, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
            if (mapped == c.MAP_FAILED or mapped == null) return error.ModuleMemoryFailed;
            {
                defer _ = c.munmap(mapped, info.expanded);
                const output = @as([*]u8, @ptrCast(mapped.?))[0..info.expanded];
                if (info.raw) {
                    try file.copyVerified(output, location.offset, info.checksum);
                } else {
                    const data = try a.alloc(u8, info.stored);
                    defer a.free(data);
                    try file.read(data, location.offset);
                    compression.inflate(data, output, info.checksum, cancel) catch |err| {
                        return if (err == error.Canceled) error.Canceled else error.CorruptCompressedModule;
                    };
                }
            }
            if (c.fcntl(fd, c.F_ADD_SEALS, @as(c_int, c.F_SEAL_WRITE | c.F_SEAL_GROW | c.F_SEAL_SHRINK | c.F_SEAL_SEAL)) != 0)
                return error.ModuleSealFailed;
        }
        try canceled(cancel);
        {
            const phase = if (kind == .image) profiling.beginExternal(@src(), "Load image codec from anonymous memory", track, depth + 1)
                else if (kind == .text) profiling.beginExternal(@src(), "Load system text from anonymous memory", track, depth + 1)
                else profiling.beginExternal(@src(), "Load diagram renderer from anonymous memory", track, depth + 1);
            defer phase.end();
            var path: [64]u8 = undefined;
            const filename = try std.fmt.bufPrint(&path, "/proc/self/fd/{d}\x00", .{fd});
            const handle = c.dlopen(filename.ptr, c.RTLD_NOW | c.RTLD_LOCAL) orelse {
                if (c.dlerror()) |detail| putError(&self.failure, std.mem.span(detail));
                return error.ModuleLoadFailed;
            };
            errdefer _ = c.dlclose(handle);
            if (kind == .image) {
                const Entry = *const fn (u32) callconv(.c) ?*const c.struct_MdfImageApi;
                const entry: Entry = @ptrCast(c.dlsym(handle, "mdf_image_api") orelse return error.ModuleAbiMismatch);
                const api = entry(c.MDF_IMAGE_ABI) orelse return error.ModuleAbiMismatch;
                if (!validImageApi(api)) return error.ModuleAbiMismatch;
                self.api = api;
            } else if (kind == .text) {
                const Entry = *const fn (u32) callconv(.c) ?*const c.struct_MdfTextApi;
                const entry: Entry = @ptrCast(c.dlsym(handle, "mdf_text_api") orelse return error.ModuleAbiMismatch);
                const api = entry(c.MDF_TEXT_ABI) orelse return error.ModuleAbiMismatch;
                if (!validTextApi(api)) return error.ModuleAbiMismatch;
                if (api.initialize.?(text_host) == 0) return error.ModuleFontsFailed;
                self.api = api;
            } else {
                const Entry = *const fn (u32) callconv(.c) ?*const Api;
                const entry: Entry = @ptrCast(c.dlsym(handle, "mdf_diagram_api") orelse return error.ModuleAbiMismatch);
                const api = entry(c.MDF_DIAGRAM_ABI) orelse return error.ModuleAbiMismatch;
                if (!validApi(api, kind)) return error.ModuleAbiMismatch;
                if (api.initialize.?(provider) == 0) return error.ModuleFontsFailed;
                self.api = api;
            }
            self.handle = handle;
            self.fd = fd;
        }
        self.stored = info.stored;
        self.expanded = info.expanded;
        self.raw = info.raw;
        self.ready_ns = profiling.nowNs();
        if (kind == .svg) profiling.signal(@src(), "SVG module ready", track)
        else if (kind == .text) profiling.signal(@src(), "System text module ready", track)
        else if (kind == .image) profiling.signal(@src(), "Image codec module ready", track)
        else profiling.signal(@src(), "Mermaid module ready", track);
    }
};

pub fn validApi(api: *const Api, kind: Kind) bool {
    return (kind == .mermaid or kind == .svg) and api.abi == c.MDF_DIAGRAM_ABI and api.size == @sizeOf(Api) and api.kind == @intFromEnum(kind) and
        api.reserved == 0 and api.initialize != null and
        (if (kind == .svg) api.svg != null and api.mermaid_svg == null else api.mermaid_svg != null and api.svg == null);
}
pub fn validImageApi(api: *const c.struct_MdfImageApi) bool {
    return api.abi == c.MDF_IMAGE_ABI and api.size == @sizeOf(c.struct_MdfImageApi) and
        api.kind == c.MDF_MODULE_IMAGE and api.reserved == 0 and api.decode != null and api.encode != null;
}
pub fn validTextApi(api: *const c.struct_MdfTextApi) bool {
    return api.abi == c.MDF_TEXT_ABI and api.size == @sizeOf(c.struct_MdfTextApi) and api.kind == c.MDF_MODULE_TEXT and api.reserved == 0 and
        api.initialize != null and api.start != null and api.complete != null and api.take != null and api.stop != null and api.destroy != null and
        api.family != null and api.@"error" != null and api.measure != null and api.bitmap != null and api.has_character != null and
        api.unknown_glyphs != null and api.add_fallback != null and api.retain_resources != null and api.release_resources != null and api.resources != null and api.from_resources != null;
}

fn putError(buffer: []u8, message: []const u8) void {
    if (buffer.len == 0) return;
    const len = @min(buffer.len - 1, message.len);
    @memcpy(buffer[0..len], message[0..len]);
    buffer[len] = 0;
}
fn description(err: anyerror) []const u8 {
    return switch (err) {
        error.Canceled => "Diagram loading canceled",
        error.UnsupportedModuleVersion => "Unsupported bundled diagram module version",
        error.InvalidModuleSize => "Invalid bundled diagram module size",
        error.CorruptCompressedModule => "Corrupt compressed diagram module: checksum or length mismatch",
        error.CorruptRawModule => "Corrupt raw diagram module: checksum or length mismatch",
        error.MissingModuleSection => "Bundled diagram module is missing or invalid",
        error.ModuleAbiMismatch => "Bundled diagram module ABI mismatch",
        error.ModuleFontsFailed => "Cannot initialize bundled diagram fonts",
        else => @errorName(err),
    };
}
var modules: [4]Module = @splat(.{});

pub export fn mdf_image_renderer(check: ?*const fn (?*const anyopaque) callconv(.c) c_int,
    context: ?*const anyopaque, depth: usize, error_buffer: ?[*]u8, error_length: usize) ?*const c.struct_MdfImageApi
{
    const api = ensureModule(c.MDF_MODULE_IMAGE, check, context, null, null, depth, .images, error_buffer, error_length) orelse return null;
    return @ptrCast(@alignCast(api));
}
pub export fn mdf_lazy_encode_png(input: ?*const c.struct_MdfPixels, length: usize, output: ?*c.struct_MdfEncodedImage) c_int {
    const out = output orelse return 0;
    out.* = std.mem.zeroes(c.struct_MdfEncodedImage);
    if (input == null) return 0;
    const untyped = ensureModule(c.MDF_MODULE_IMAGE, null, null, null, null, 0, .gui, null, 0) orelse return 0;
    const api: *const c.struct_MdfImageApi = @ptrCast(@alignCast(untyped));
    return api.encode.?(input, length, out);
}

pub export fn mdf_diagram_renderer(kind_value: u32, check: ?*const fn (?*const anyopaque) callconv(.c) c_int, context: ?*const anyopaque, provider: c.MdfBuiltinFont, depth: usize, error_buffer: ?[*]u8, error_length: usize) ?*const Api {
    if (kind_value < 1 or kind_value > 2 or provider == null) return null;
    const api = ensureModule(kind_value, check, context, provider, null, depth, .images, error_buffer, error_length) orelse return null;
    return @ptrCast(@alignCast(api));
}
pub export fn mdf_text_renderer(host: ?*const c.struct_MdfTextHost, track_value: u8,
    check: ?*const fn (?*const anyopaque) callconv(.c) c_int, context: ?*const anyopaque, depth: usize,
    error_buffer: ?[*]u8, error_length: usize) ?*const c.struct_MdfTextApi
{
    if (host == null) return null;
    const track = std.enums.fromInt(profiling.Track, track_value) orelse .fonts;
    const api = ensureModule(3, check, context, null, host, depth, track, error_buffer, error_length) orelse return null;
    return @ptrCast(@alignCast(api));
}
fn ensureModule(kind_value: u32, check: ?*const fn (?*const anyopaque) callconv(.c) c_int, context: ?*const anyopaque,
    provider: c.MdfBuiltinFont, text_host: ?*const c.struct_MdfTextHost, depth: usize, track: profiling.Track,
    error_buffer: ?[*]u8, error_length: usize) ?*const anyopaque
{
    const kind = std.enums.fromInt(Kind, kind_value) orelse return null;
    const cancel = compression.Cancel{ .check = check, .context = context };
    const module = &modules[kind_value - 1];
    while (true) {
        canceled(cancel) catch {
            if (error_buffer) |ptr| putError(ptr[0..error_length], description(error.Canceled));
            return null;
        };
        const state = module.state.load(.acquire);
        if (state == 2) return module.api;
        if (state == 3) {
            if (error_buffer) |ptr| putError(ptr[0..error_length], std.mem.sliceTo(&module.failure, 0));
            return null;
        }
        if (state == 0 and module.state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            module.prepare(kind, cancel, provider, text_host, depth, track) catch |err| {
                if (err != error.ModuleLoadFailed) putError(&module.failure, description(err));
                if (error_buffer) |ptr| putError(ptr[0..error_length], std.mem.sliceTo(&module.failure, 0));
                module.state.store(if (err == error.Canceled) 0 else 3, .release);
                _ = std.os.linux.futex_3arg(&module.state, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
                return null;
            };
            module.state.store(2, .release);
            _ = std.os.linux.futex_3arg(&module.state, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
            return module.api;
        }
        // Poll cancellation even while another document finishes its load.
        const timeout: std.os.linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.os.linux.futex_4arg(&module.state, .{ .cmd = .WAIT, .private = true }, 1, &timeout);
    }
}
pub const Stats = extern struct { ready_ns: u64 = 0, stored: u64 = 0, expanded: u64 = 0, flags: u32 = 0 };
pub export fn mdf_diagram_stats(kind: u32) Stats {
    if (kind < 1 or kind > 4) return .{};
    const module = &modules[kind - 1];
    if (module.state.load(.acquire) != 2) return .{};
    return .{ .ready_ns = module.ready_ns, .stored = module.stored, .expanded = module.expanded, .flags = if (module.raw) c.MDF_MODULE_PAYLOAD_RAW else 0 };
}
pub export fn mdf_svg_image(bytes: ?[*]const u8, length: usize) bool {
    const ptr = bytes orelse return false;
    var text = ptr[0..@min(length, 4096)];
    if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text = text[3..];
    text = std.mem.trimStart(u8, text, " \t\r\n");
    return text.len > 0 and text[0] == '<' and
        (std.mem.indexOf(u8, text, "<svg") != null or std.mem.indexOf(u8, text, ":svg") != null);
}
