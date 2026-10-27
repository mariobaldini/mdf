//! Minimal process entry. Only libc is eager; the UI engine loads on a worker.
const std = @import("std");
const c = @import("startup_native");
const Buffer = c.struct_Buffer;
const Wake = *const fn () callconv(.c) void;
extern fn mdf_now_ns() u64;
extern fn mdf_core_create([*]const u8, usize, bool, u64, Wake) ?*c.struct_MdfCore;
extern fn mdf_core_destroy(*c.struct_MdfCore) void;
extern fn mdf_core_open(*c.struct_MdfCore, [*]const u8, usize) Buffer;
extern fn mdf_core_poll(*c.struct_MdfCore) Buffer;
extern fn mdf_buffer_free(Buffer) void;
extern fn mdf_notices() Buffer;
extern fn mdf_startup_fonts_begin() void;
extern fn mdf_startup_fonts_end() void;
extern fn mdf_profile_event(u8, [*]const u8, usize, [*]const u8, usize, u32, u64, u64, usize, bool) void;
extern fn mdf_profile_signal(u8, [*]const u8, usize, [*]const u8, usize, u32, u64) void;

const source = "frontend/launcher.zig";
const version = @import("app_version").value;
const max_ui = 256 * 1024 * 1024;
var wake_fd: c_int = -1;

fn wake() callconv(.c) void {
    const one: u64 = 1;
    _ = c.write(wake_fd, &one, @sizeOf(u64));
}
fn write(fd: c_int, text: []const u8) void {
    var at: usize = 0;
    while (at < text.len) {
        const count = c.write(fd, text[at..].ptr, text.len - at);
        if (count < 0 and c.__errno_location().* == c.EINTR) continue;
        if (count <= 0) return;
        at += @intCast(count);
    }
}
fn event(comptime name: []const u8, track: u8, start: u64, waiting: bool) void {
    mdf_profile_event(track, name.ptr, name.len, source.ptr, source.len, @src().line, start, mdf_now_ns() - start, 0, waiting);
}
fn signal(comptime name: []const u8, track: u8) void {
    mdf_profile_signal(track, name.ptr, name.len, source.ptr, source.len, @src().line, mdf_now_ns());
}
fn readAt(fd: c_int, bytes: []u8, offset: u64, file_size: u64) !void {
    if (offset > file_size or bytes.len > file_size - offset) return error.TruncatedUiEngine;
    var at: usize = 0;
    while (at < bytes.len) {
        const count = c.pread(fd, bytes[at..].ptr, bytes.len - at, @intCast(offset + at));
        if (count < 0 and c.__errno_location().* == c.EINTR) continue;
        if (count <= 0) return error.CannotReadUiEngine;
        at += @intCast(count);
    }
}

fn takeDocument(core: *c.struct_MdfCore) Buffer {
    const started = mdf_now_ns();
    const result = mdf_core_poll(core);
    if (result.ptr != null) event("Adopt early document and start assets", 0, started, false);
    return result;
}

const Ui = struct {
    start: std.atomic.Value(u32) = .init(0),
    dependencies_available: std.atomic.Value(u32) = .init(0),
    dependencies_done: std.atomic.Value(u32) = .init(0),
    dependencies: [8192]u8 = @splat(0),
    dependencies_len: usize = 0,
    done: std.atomic.Value(bool) = .init(false),
    api: ?*const c.struct_MdfFrontendApi = null,
    bytes: u64 = 0,
    ready_ns: u64 = 0,
    failure: ?anyerror = null,
    detail: [512]u8 = @splat(0),

    fn wait(value: *std.atomic.Value(u32)) u32 {
        while (value.load(.acquire) == 0) _ = std.os.linux.futex_4arg(value, .{ .cmd = .WAIT, .private = true }, 0, null);
        return value.load(.acquire);
    }
    fn release(value: *std.atomic.Value(u32), state: u32) void {
        value.store(state, .release);
        _ = std.os.linux.futex_3arg(value, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
    }

    fn preload(self: *Ui) void {
        _ = wait(&self.start);
        _ = c.pthread_setname_np(c.pthread_self(), "mdf-ui-libs");
        _ = wait(&self.dependencies_available);
        const began = mdf_now_ns();
        var at: usize = 0;
        while (at < self.dependencies_len) {
            const rest = self.dependencies[at..self.dependencies_len];
            const end = std.mem.indexOfScalar(u8, rest, 0) orelse break;
            // Packer records DT_NEEDED sonames. Normal dlopen still handles
            // resolution and errors; this pass only prepares mandatory libs.
            if (end > 0 and std.mem.indexOfScalar(u8, rest[0..end], '/') == null) {
                const loading = mdf_now_ns();
                _ = c.dlopen(@ptrCast(rest.ptr), c.RTLD_LAZY | c.RTLD_LOCAL);
                mdf_profile_event(8, rest.ptr, end, source.ptr, source.len, @src().line, loading, mdf_now_ns() - loading, 1, false);
            }
            at += end + 1;
        }
        event("Preload UI graphics and font libraries", 8, began, false);
        signal("UI dependencies ready", 8);
        release(&self.dependencies_done, 1);
    }

    fn run(self: *Ui) void {
        if (wait(&self.start) == 2) return;
        _ = c.pthread_setname_np(c.pthread_self(), "mdf-ui");
        self.load() catch |err| {
            self.failure = err;
        };
        release(&self.dependencies_available, 1);
        self.ready_ns = mdf_now_ns();
        if (self.failure == null) signal("UI engine ready", 7);
        self.done.store(true, .release);
        wake();
    }

    fn load(self: *Ui) !void {
        const started = mdf_now_ns();
        const executable = c.open("/proc/self/exe", c.O_RDONLY | c.O_CLOEXEC);
        if (executable < 0) return error.CannotOpenExecutable;
        defer _ = c.close(executable);
        var info: c.struct_stat = undefined;
        if (c.fstat(executable, &info) != 0 or info.st_size < @sizeOf(c.Elf64_Ehdr)) return error.InvalidExecutable;
        const length: u64 = @intCast(info.st_size);
        var header: c.Elf64_Ehdr = undefined;
        try readAt(executable, std.mem.asBytes(&header), 0, length);
        if (!std.mem.eql(u8, header.e_ident[0..6], "\x7fELF\x02\x01") or header.e_machine != 62 or
            header.e_shentsize != @sizeOf(c.Elf64_Shdr) or header.e_shnum == 0 or header.e_shnum > 4096 or
            header.e_shstrndx >= header.e_shnum) return error.InvalidExecutable;
        const sections = try std.heap.c_allocator.alloc(c.Elf64_Shdr, header.e_shnum);
        defer std.heap.c_allocator.free(sections);
        try readAt(executable, std.mem.sliceAsBytes(sections), header.e_shoff, length);
        const names = sections[header.e_shstrndx];
        if (names.sh_size == 0 or names.sh_size > 1024 * 1024) return error.InvalidExecutable;
        const strings = try std.heap.c_allocator.alloc(u8, @intCast(names.sh_size));
        defer std.heap.c_allocator.free(strings);
        try readAt(executable, strings, names.sh_offset, length);
        var payload: ?c.Elf64_Shdr = null;
        var dependencies: ?c.Elf64_Shdr = null;
        for (sections) |section| {
            const name = ".mdf_ui\x00";
            if (section.sh_name <= strings.len and name.len <= strings.len - section.sh_name and
                std.mem.eql(u8, strings[section.sh_name..][0..name.len], name))
            {
                if (payload != null) return error.DuplicateUiEngine;
                payload = section;
            }
            const deps = ".mdf_ui_deps\x00";
            if (section.sh_name <= strings.len and deps.len <= strings.len - section.sh_name and
                std.mem.eql(u8, strings[section.sh_name..][0..deps.len], deps))
            {
                if (dependencies != null) return error.DuplicateUiDependencies;
                dependencies = section;
            }
        }
        const section = payload orelse return error.MissingUiEngine;
        if (section.sh_type != c.SHT_PROGBITS or section.sh_flags & c.SHF_ALLOC != 0 or
            section.sh_size < 64 or section.sh_size > max_ui or section.sh_offset > length or
            section.sh_size > length - section.sh_offset) return error.InvalidUiEngine;
        var module_header: c.Elf64_Ehdr = undefined;
        try readAt(executable, std.mem.asBytes(&module_header), section.sh_offset, length);
        if (!std.mem.eql(u8, module_header.e_ident[0..6], "\x7fELF\x02\x01") or module_header.e_type != c.ET_DYN or
            module_header.e_machine != 62) return error.InvalidUiEngine;
        self.bytes = section.sh_size;
        if (dependencies) |deps| {
            if (deps.sh_type != c.SHT_PROGBITS or deps.sh_flags & c.SHF_ALLOC != 0 or deps.sh_size > self.dependencies.len)
                return error.InvalidUiDependencies;
            const count: usize = @intCast(deps.sh_size);
            try readAt(executable, self.dependencies[0..count], deps.sh_offset, length);
            if (count > 0 and self.dependencies[count - 1] != 0) return error.InvalidUiDependencies;
            self.dependencies_len = count;
        }
        signal("Request UI dependencies", 7);
        release(&self.dependencies_available, 1);
        var flags: c_uint = c.MFD_CLOEXEC | c.MFD_ALLOW_SEALING;
        if (@hasDecl(c, "MFD_EXEC")) flags |= c.MFD_EXEC;
        var memory = c.memfd_create("mdf-ui", flags);
        if (@hasDecl(c, "MFD_EXEC") and memory < 0 and c.__errno_location().* == c.EINVAL)
            memory = c.memfd_create("mdf-ui", c.MFD_CLOEXEC | c.MFD_ALLOW_SEALING);
        if (memory < 0) return error.CannotAllocateUiEngine;
        defer _ = c.close(memory);
        var offset: c.off_t = @intCast(section.sh_offset);
        var remaining = section.sh_size;
        while (remaining > 0) {
            const copied = c.sendfile(memory, executable, &offset, @intCast(remaining));
            if (copied < 0 and c.__errno_location().* == c.EINTR) continue;
            if (copied <= 0) return error.CannotCopyUiEngine;
            remaining -= @intCast(copied);
        }
        if (c.fcntl(memory, c.F_ADD_SEALS, @as(c_int, c.F_SEAL_WRITE | c.F_SEAL_GROW | c.F_SEAL_SHRINK | c.F_SEAL_SEAL)) != 0)
            return error.CannotSealUiEngine;
        event("Prepare anonymous UI image", 7, started, false);
        self.readAhead();
        if (self.dependencies_done.load(.acquire) == 0) {
            const waiting = mdf_now_ns();
            _ = wait(&self.dependencies_done);
            event("Wait for UI dependency loader", 7, waiting, true);
        }
        signal("UI dependencies adopted", 7);
        const loading = mdf_now_ns();
        defer event("Link and initialize UI engine", 7, loading, false);
        var buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&buffer, "/proc/self/fd/{d}", .{memory}, 0);
        try self.bind(path.ptr);
    }

    // Optional cold-load hints. Normal dlopen retains authority over
    // soname resolution and custom library paths; these opens execute no code.
    fn readAhead(self: *Ui) void {
        if (self.dependencies_done.load(.acquire) != 0) return;
        const began = mdf_now_ns();
        // Follow this UI's DT_NEEDED list, including Wayland/libm. In a
        // bundled build, reading unused system Pango/Cairo only adds disk I/O.
        var names = std.mem.splitScalar(u8, self.dependencies[0..self.dependencies_len], 0);
        while (names.next()) |name| {
            if (self.dependencies_done.load(.acquire) != 0) break;
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or
                std.mem.eql(u8, name, "libc.so.6")) continue; // Already eager.
            readAheadName(name);
        }
        // Large indirect dependencies of the system text stack. These are
        // hints only; dlopen still resolves the complete dependency graph.
        for ([_][]const u8{ "libpcre2-8.so.0", "libffi.so.8", "libgraphite2.so.3", "libxml2.so.2" }) |name| {
            if (self.dependencies_done.load(.acquire) != 0) break;
            readAheadName(name);
        }
        event("Read ahead UI-library pages", 7, began, false);
    }

    fn readAheadName(name: []const u8) void {
        for ([_][]const u8{ "/lib64/", "/usr/lib64/", "/lib/x86_64-linux-gnu/", "/usr/lib/x86_64-linux-gnu/" }) |directory| {
            var buffer: [128]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&buffer, "{s}{s}", .{ directory, name }, 0) catch continue;
            const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
            if (fd < 0) continue;
            _ = c.posix_fadvise(fd, 0, 0, c.POSIX_FADV_WILLNEED);
            _ = c.close(fd);
            break;
        }
    }

    fn bind(self: *Ui, path: [*:0]const u8) !void {
        const handle = c.dlopen(path, c.RTLD_LAZY | c.RTLD_LOCAL) orelse {
            if (c.dlerror()) |detail| {
                const bytes = std.mem.span(detail);
                @memcpy(self.detail[0..@min(bytes.len, self.detail.len - 1)], bytes[0..@min(bytes.len, self.detail.len - 1)]);
            }
            return error.CannotLoadUiEngine;
        };
        // Keep the module loaded for process lifetime, including TLS destructors.
        const Query = *const fn (u32) callconv(.c) ?*const c.struct_MdfFrontendApi;
        const query: Query = @ptrCast(c.dlsym(handle, "mdf_frontend_api") orelse return error.MissingUiApi);
        const api = query(c.MDF_FRONTEND_ABI) orelse return error.UiAbiMismatch;
        if (api.abi != c.MDF_FRONTEND_ABI or api.size != @sizeOf(c.struct_MdfFrontendApi) or api.run == null)
            return error.UiAbiMismatch;
        self.api = api;
    }
};

fn launch(argc: c_int, argv: [*][*:0]u8, origin: u64) !c_int {
    var options = c.struct_MdfLaunchOptions{ .path = "", .capture = "", .anchor = "", .flags = 0 };
    var index: usize = 1;
    while (index < @as(usize, @intCast(argc))) : (index += 1) {
        const arg = std.mem.span(argv[index]);
        if (std.mem.eql(u8, arg, "--version")) {
            write(1, "mdf " ++ version ++ "\n");
            return 0;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            write(1, "Markdown FAST " ++ version ++ "\nUsage: mdf [FILE.md]\n  --version    Show version\n  --licenses   Print third-party notices\n  --profile    Report startup metrics and exit\n  --profile-scroll Report startup and scrolling metrics\n  --capture PNG Save the ready frame with --profile\n  --capture-anchor ID Select a heading for --capture\n  --capture-reader Capture the reader with navigation hidden\nRequires a Linux Wayland session.\n");
            return 0;
        }
        if (std.mem.eql(u8, arg, "--licenses")) {
            const bytes = mdf_notices();
            if (bytes.ptr != null) write(1, bytes.ptr[0..bytes.len]);
            return 0;
        }
        if (std.mem.eql(u8, arg, "--profile")) options.flags |= c.MDF_LAUNCH_PROFILE else if (std.mem.eql(u8, arg, "--benchmark") or std.mem.eql(u8, arg, "--bench")) options.flags |= c.MDF_LAUNCH_BENCHMARK else if (std.mem.eql(u8, arg, "--profile-scroll")) options.flags |= c.MDF_LAUNCH_PROFILE | c.MDF_LAUNCH_SCROLL else if (std.mem.eql(u8, arg, "--self-test")) options.flags |= c.MDF_LAUNCH_PROFILE | c.MDF_LAUNCH_TEST else if (std.mem.eql(u8, arg, "--capture-reader")) options.flags |= c.MDF_LAUNCH_READER else if (std.mem.eql(u8, arg, "--capture") or std.mem.eql(u8, arg, "--capture-anchor")) {
            index += 1;
            if (index == argc) {
                write(2, if (std.mem.eql(u8, arg, "--capture")) "mdf: --capture requires a PNG path\n" else "mdf: --capture-anchor requires a heading ID\n");
                return 1;
            }
            if (std.mem.eql(u8, arg, "--capture")) options.capture = argv[index] else options.anchor = argv[index];
        } else if (arg.len > 0 and arg[0] == '-') {
            write(2, "mdf: Unknown option: ");
            write(2, arg);
            write(2, "\n");
            return 1;
        } else if (options.path[0] != 0) {
            write(2, "mdf: Open one document at a time\n");
            return 1;
        } else options.path = argv[index];
    }
    const profile = options.flags & (c.MDF_LAUNCH_PROFILE | c.MDF_LAUNCH_BENCHMARK) != 0;
    if (profile and options.path[0] == 0) {
        write(2, "mdf: Profiling requires a Markdown file\n");
        return 1;
    }
    if ((options.anchor[0] != 0 or options.flags & c.MDF_LAUNCH_READER != 0) and (options.capture[0] == 0 or !profile)) {
        write(2, "mdf: Capture options require --capture and --profile or --benchmark\n");
        return 1;
    }
    if (c.getenv("WAYLAND_DISPLAY") == null and c.getenv("WAYLAND_SOCKET") == null) {
        write(2, "mdf: Markdown FAST requires a Wayland session (WAYLAND_DISPLAY is not set).\n");
        return 1;
    }
    if (c.setenv("FLTK_BACKEND", "wayland", 1) != 0 or c.setenv("GDK_BACKEND", "wayland", 1) != 0) return error.CannotSetBackend;
    wake_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
    if (wake_fd < 0) return error.CannotCreateBootstrapWake;
    defer {
        _ = c.close(wake_fd);
        wake_fd = -1;
    }
    const home = if (c.getenv("HOME")) |value| std.mem.span(value) else "";
    const started = mdf_now_ns();
    const core = mdf_core_create(home.ptr, home.len, profile, origin, wake) orelse return error.CannotCreateDocumentCore;
    defer mdf_core_destroy(core);
    event("Create bootstrap document workers", 0, started, false);
    var startup = c.struct_MdfStartup{ .abi = c.MDF_FRONTEND_ABI, .size = @sizeOf(c.struct_MdfStartup), .core = core, .document = .{ .ptr = null, .len = 0 }, .origin_ns = origin, .ui_ready_ns = 0, .ui_module_bytes = 0, .options = options };
    defer if (startup.document.ptr != null) mdf_buffer_free(startup.document);
    if (options.path[0] != 0) {
        const path = std.mem.span(options.path);
        const request = mdf_core_open(core, path.ptr, path.len);
        if (request.ptr != null and std.mem.indexOf(u8, request.ptr[0..request.len], "\"err\"") != null)
            startup.document = request
        else
            mdf_buffer_free(request);
    }
    // Byte inflation needs no Fontconfig/Pango or loader calls. Start it before
    // any dlopen, alongside parsing; join before the core recorder is destroyed.
    mdf_startup_fonts_begin();
    defer mdf_startup_fonts_end();
    var ui = Ui{};
    signal("Request UI engine", 0);
    const worker = try std.Thread.spawn(.{}, Ui.run, .{&ui});
    const dependency_worker = std.Thread.spawn(.{}, Ui.preload, .{&ui}) catch |err| {
        Ui.release(&ui.start, 2);
        worker.join();
        return err;
    };
    // Create every bootstrap thread before any dlopen: the loader lock can
    // otherwise serialize pthread TLS setup and delay independent parsing.
    Ui.release(&ui.start, 1);
    while (!ui.done.load(.acquire)) {
        if (startup.document.ptr == null and options.path[0] != 0) startup.document = takeDocument(core);
        if (ui.done.load(.acquire)) break;
        const wait_start = mdf_now_ns();
        var descriptor = c.struct_pollfd{ .fd = wake_fd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&descriptor, 1, -1);
        event("Wait for UI engine / document worker", 0, wait_start, true);
        if (ready > 0) {
            var value: u64 = 0;
            _ = c.read(wake_fd, &value, @sizeOf(u64));
        }
    }
    const joining = mdf_now_ns();
    worker.join();
    dependency_worker.join();
    event("Join bootstrap UI workers", 0, joining, true);
    if (ui.failure) |err| {
        write(2, "mdf: Cannot prepare bundled UI engine: ");
        write(2, @errorName(err));
        if (ui.detail[0] != 0) {
            write(2, ": ");
            write(2, std.mem.sliceTo(&ui.detail, 0));
        }
        write(2, "\n");
        return 1;
    }
    if (startup.document.ptr == null and options.path[0] != 0) startup.document = takeDocument(core);
    startup.ui_ready_ns = ui.ready_ns;
    startup.ui_module_bytes = ui.bytes;
    return ui.api.?.run.?(&startup);
}

pub export fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    const origin = mdf_now_ns();
    return launch(argc, argv, origin) catch |err| {
        write(2, "mdf: ");
        write(2, @errorName(err));
        write(2, "\n");
        return 1;
    };
}
