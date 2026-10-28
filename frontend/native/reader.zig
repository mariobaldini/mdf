//! Shared-layout reader painted with z2d. The window backend supplies a canvas
//! and drives this same reader when document, viewport or font state changes.
const std = @import("std");
const c = @import("native");
const profile=@import("ui_profile");
const paint = @import("canvas.zig");
const ImageStore = @import("image-store.zig").Store;
pub const diagrams = @import("diagram.zig");
pub fn bytes(value: c.Buffer) []const u8 {
    return if (value.ptr != null) value.ptr[0..value.len] else "";
}
fn kind(block: c.MdfBlockView, name: []const u8) bool {
    return std.mem.eql(u8, bytes(block.kind), name);
}
pub const Reader = struct {
    pub const Hit = struct { position: usize, block: usize, link: []const u8 = "" };
    pub const Range = struct { first: usize, last: usize };
    const DiagramBox = struct { left: f32, width: f32 };
    allocator: std.mem.Allocator,
    core: *c.MdfCore,
    viewport: *c.MdfViewport,
    canvas: *paint.Canvas,
    layouts: []?*c.MdfBlockLayout,
    details_open: []bool,
    columns: std.AutoHashMapUnmanaged(usize, c.MdfFloatBuffer) = .empty,
    zoom: f32 = 1,
    wrap: bool = true,
    width_mode: u32 = 1,
    wrapped_right: f32 = 0,
    diagram_states: std.AutoHashMapUnmanaged(usize, diagrams.State) = .empty,
    diagram_focus: ?usize = null,
    diagram_drag: ?struct { x: f32, horizontal: f32 } = null,
    diagram_control: bool = false,
    images: ?*ImageStore = null,
    failure: ?anyerror = null,
    selection: ?Range = null,
    pressed: ?Hit = null,
    dragging: bool = false,

    pub fn init(a: std.mem.Allocator, core: *c.MdfCore, canvas: *paint.Canvas) !Reader {
        const timing=profile.begin(canvas.profiling,@src(),"Initialize native document layout",0);
        defer timing.end();
        const doc = c.mdf_core_document_text(core);
        var self = initial: {
            const viewport = c.mdf_viewport_create() orelse return error.OutOfMemory;
            errdefer c.mdf_viewport_destroy(viewport);
            const layouts = try a.alloc(?*c.MdfBlockLayout, doc.count);
            errdefer a.free(layouts);
            @memset(layouts, null);
            const details = try a.alloc(bool, doc.count);
            for (details, 0..) |*open, index| open.* = c.mdf_core_block(core, index).flags & 1 != 0;
            break :initial Reader{ .allocator = a, .core = core, .viewport = viewport, .canvas = canvas, .layouts = layouts, .details_open = details };
        };
        errdefer self.deinit();
        const viewport = self.viewport;
        const advance = try canvas.measure(.{ .face = 0, .size = 17, .flags = 0 }, "m");
        c.mdf_viewport_configure(viewport, @floatFromInt(canvas.logical_width), 1, advance.width, true);
        if (!c.mdf_viewport_resize(viewport, doc.count)) return error.OutOfMemory;
        const geometry = c.mdf_viewport_view(viewport);
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(viewport);
        for (0..doc.count) |index| {
            const block = c.mdf_core_block(core, index);
            const size = c.mdf_text_style(if (kind(block, "heading")) 1 else if (kind(block, "code")) 2 else 0, block.heading, 0, block.flags & 4 != 0, self.zoom).size;
            geometry.heights[index] = if (!self.visible(index)) 0 else c.mdf_estimate_block(if (kind(block, "rule")) 3 else if (kind(block, "heading")) 1 else 0,
                block.bytes, block.lines, block.indent, block.quote, @floatFromInt(size), self.zoom, fields.content_width, self.wrap);
        }
        if (!c.mdf_viewport_reindex(viewport)) return error.OutOfMemory;
        return self;
    }
    pub fn deinit(self: *Reader) void {
        for (self.layouts) |entry| if (entry) |value| c.mdf_layout_result_free(value);
        self.allocator.free(self.layouts);
        self.allocator.free(self.details_open);
        var values = self.columns.valueIterator();
        while (values.next()) |value| c.mdf_float_buffer_free(value.*);
        self.columns.deinit(self.allocator);
        self.diagram_states.deinit(self.allocator);
        c.mdf_viewport_destroy(self.viewport);
    }
    fn visible(self: *Reader, index: usize) bool {
        var parent = c.mdf_core_block(self.core, index).parent;
        var remaining = self.layouts.len;
        while (parent >= 0) {
            if (remaining == 0 or parent >= self.layouts.len) return false;
            remaining -= 1;
            const block = c.mdf_core_block(self.core, @intCast(parent));
            if (!self.details_open[@intCast(parent)]) return false;
            parent = block.parent;
        }
        return true;
    }
    fn measure(context: ?*anyopaque, font: c.MdfLayoutFont, text: [*c]const u8, len: usize) callconv(.c) c.MdfFlowMetrics {
        const self: *Reader = @ptrCast(@alignCast(context.?));
        return self.canvas.measure(font, text[0..len]) catch |err| {
            self.failure = err;
            return .{ .width = std.math.nan(f32), .height = 0, .descent = 0 };
        };
    }
    fn columnWidths(context: ?*anyopaque, index: usize, width: f32, count: [*c]usize) callconv(.c) [*c]const f32 {
        const self: *Reader = @ptrCast(@alignCast(context.?));
        const result = self.table(index, width) catch |err| {
            self.failure = err;
            count[0] = 0;
            return null;
        };
        count[0] = result.count;
        return result.data;
    }
    fn table(self: *Reader, row: usize, width: f32) !c.MdfFloatBuffer {
        var index = row;
        while (index > 0 and c.mdf_core_block(self.core, index).flags & 4 == 0 and kind(c.mdf_core_block(self.core, index - 1), "table_row")) index -= 1;
        if (self.columns.get(index)) |value| return value;
        var result = std.mem.zeroes(c.MdfFloatBuffer);
        const depth=profile.nestingDepth();
        const nesting=profile.enter(depth+1);
        defer nesting.end();
        if (!c.mdf_core_table_columns(self.core, index, width, self.zoom, self.wrap, self.canvas.monoReady(), measure, self, depth, &result))
            return self.failure orelse error.TableMeasurementFailed;
        errdefer c.mdf_float_buffer_free(result);
        try self.columns.put(self.allocator, index, result);
        return result;
    }
    fn layout(self: *Reader, index: usize) !*c.MdfBlockLayout {
        if (self.layouts[index]) |cached| return cached;
        const timing=profile.begin(self.canvas.profiling,@src(),"Layout native Markdown block",0);
        defer timing.end();
        const options = self.layoutOptions(index, true);
        const result = c.mdf_core_layout_block(self.core, index, &options, measure, columnWidths, self) orelse
            return self.failure orelse error.BlockLayoutFailed;
        self.layouts[index] = result;
        if (self.wrap and (kind(c.mdf_core_block(self.core, index), "table_row") or self.mermaid(index) != null)) {
            const fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
            self.wrapped_right = @max(self.wrapped_right, c.mdf_layout_result_view(result).right + fields.margin);
            fields.horizontal_dirty = true;
        }
        return result;
    }
    fn layoutOptions(self: *Reader, index: usize, collect: bool) c.MdfLayoutOptions {
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
        const image = if (self.images) |images| images.values.getPtr(index) else null;
        const ready = if (image) |value| value.pixels.data != null else false;
        const message = if (image) |value| value.message() else "";
        const diagram = self.mermaid(index);
        const box: DiagramBox = if (diagram != null) self.diagramBox(index) else .{ .left = 0, .width = 0 };
        return .{ .content_width = fields.content_width, .margin = fields.margin, .zoom = self.zoom,
            .wrap = self.wrap, .collect = collect, .mono_ready = self.canvas.monoReady(), .visible = self.visible(index),
            .image_ready = ready, .logical_image = if (image) |value| value.diagram else false,
            .image_width = if (image) |value| (if (value.diagram) value.logical_width else @floatFromInt(value.pixels.width)) else 0,
            .image_height = if (image) |value| (if (value.diagram) value.logical_height else @floatFromInt(value.pixels.height)) else 0,
            .failure = .{ .ptr = message.ptr, .len = message.len },
            .diagram_scale = if (diagram) |value| self.diagramState(index).factor(box.width, value.logical_width * self.zoom) else 0,
            .diagram_controls_height = if (diagram != null) diagrams.Controls.init(box.left, 0, box.width).height else 0,
            .boundaries = null };
    }
    fn mermaid(self: *Reader, index: usize) ?*const @import("image-store.zig").Image {
        const images = self.images orelse return null;
        const image = images.values.getPtr(index) orelse return null;
        return if (image.diagram and !image.svg and image.pixels.data != null) image else null;
    }
    pub fn diagramState(self: *Reader, index: usize) diagrams.State {
        return self.diagram_states.get(index) orelse .{};
    }
    fn diagramBox(self: *Reader, index: usize) DiagramBox {
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
        const block = c.mdf_core_block(self.core, index);
        const indent = @as(f32, @floatFromInt(@min(20, block.indent +| block.quote))) * 22 * self.zoom;
        return .{ .left = fields.margin + indent, .width = @max(30, fields.content_width - indent) };
    }
    fn refreshOverflow(self: *Reader) void {
        self.wrapped_right = 0;
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
        for (self.layouts, 0..) |entry, index| if (entry) |value| {
            if (kind(c.mdf_core_block(self.core, index), "table_row") or self.mermaid(index) != null)
                self.wrapped_right = @max(self.wrapped_right, c.mdf_layout_result_view(value).right + fields.margin);
        };
        fields.horizontal_dirty = true;
    }
    pub fn zoomDiagram(self: *Reader, index: usize, action: diagrams.Action) !void {
        const image = self.mermaid(index) orelse return;
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
        const box = self.diagramBox(index);
        var state = self.diagramState(index);
        const factor = state.factor(box.width, image.logical_width * self.zoom);
        self.diagram_focus = index;
        if (!diagrams.State.enabled(action, factor)) return;
        state.apply(action, factor);
        try self.diagram_states.put(self.allocator, index, state);
        var geometry = c.mdf_viewport_view(self.viewport);
        const anchor = c.mdf_viewport_index_at(self.viewport, fields.scroll, self.layouts.len);
        const delta = fields.scroll - geometry.offsets[anchor];
        if (self.layouts[index]) |value| c.mdf_layout_result_free(value);
        self.layouts[index] = null;
        geometry.heights[index] = c.mdf_layout_result_view(try self.layout(index)).height;
        if (!c.mdf_viewport_reindex(self.viewport)) return error.OutOfMemory;
        geometry = c.mdf_viewport_view(self.viewport);
        fields.scroll = geometry.offsets[anchor] + delta;
        self.refreshOverflow();
        c.mdf_viewport_move(self.viewport, fields.scroll, @floatFromInt(self.canvas.logical_height));
    }
    pub const DiagramHit = struct { index: usize, action: ?diagrams.Action = null, image: bool = false };
    pub fn diagramAt(self: *Reader, x: f32, y: f32) ?DiagramHit {
        if (self.layouts.len == 0) return null;
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
        const geometry = c.mdf_viewport_view(self.viewport);
        const index = c.mdf_viewport_index_at(self.viewport, y + fields.scroll, self.layouts.len);
        _ = self.mermaid(index) orelse return null;
        const value = self.layouts[index] orelse return null;
        const view = c.mdf_layout_result_view(value);
        if (!view.image) return null;
        const box = self.diagramBox(index);
        const py = y + fields.scroll - geometry.offsets[index];
        const height = diagrams.Controls.init(box.left, 0, box.width).height;
        const controls = diagrams.Controls.init(box.left, view.iy - height, box.width);
        if (controls.hit(x, py)) |action| return .{ .index = index, .action = action };
        const image: diagrams.Box = .{ .x = view.ix - fields.horizontal_scroll, .y = view.iy, .width = view.iw, .height = view.ih };
        return if (image.contains(x, py)) .{ .index = index, .image = true } else null;
    }
    pub fn prepare(self: *Reader) !void {
        const timing=profile.begin(self.canvas.profiling,@src(),"Measure visible Markdown blocks",0);
        defer timing.end();
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
        for (0..8) |_| {
            var geometry = c.mdf_viewport_view(self.viewport);
            const first = c.mdf_viewport_index_at(self.viewport, fields.scroll, self.layouts.len);
            if (geometry.offset_count == 0) break;
            const delta = fields.scroll - geometry.offsets[first];
            var changed = false;
            var index = first;
            while (index < self.layouts.len and geometry.offsets[index] < fields.scroll + @as(f32, @floatFromInt(self.canvas.logical_height)) + 100) : (index += 1) {
                if (self.layouts[index] == null) {
                    const value = try self.layout(index);
                    geometry.heights[index] = c.mdf_layout_result_view(value).height;
                    changed = true;
                }
            }
            if (!changed) break;
            if (!c.mdf_viewport_reindex(self.viewport)) return error.OutOfMemory;
            geometry = c.mdf_viewport_view(self.viewport);
            fields.scroll = geometry.offsets[first] + delta;
        }
        c.mdf_viewport_move(self.viewport, fields.scroll, @floatFromInt(self.canvas.logical_height));
    }
    pub fn jump(self: *Reader, anchor: []const u8) void {
        var index: usize = 0;
        if (c.mdf_core_find_anchor(self.core, anchor.ptr, anchor.len, &index) and index < self.layouts.len) {
            var parent = c.mdf_core_block(self.core, index).parent;
            while (parent >= 0 and parent < self.details_open.len) {
                self.details_open[@intCast(parent)] = true;
                parent = c.mdf_core_block(self.core, @intCast(parent)).parent;
            }
            self.invalidate() catch |err| {
                self.failure = err;
                return;
            };
            const geometry = c.mdf_viewport_view(self.viewport);
            c.mdf_viewport_move(self.viewport, geometry.offsets[index], @floatFromInt(self.canvas.logical_height));
        }
    }
    pub fn invalidate(self: *Reader) !void {
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
        var geometry = c.mdf_viewport_view(self.viewport);
        const anchor = c.mdf_viewport_index_at(self.viewport, fields.scroll, self.layouts.len);
        const delta = if (geometry.offset_count > 0) fields.scroll - geometry.offsets[anchor] else 0;
        for (self.layouts) |*entry| {
            if (entry.*) |value| c.mdf_layout_result_free(value);
            entry.* = null;
        }
        var values = self.columns.valueIterator();
        while (values.next()) |value| c.mdf_float_buffer_free(value.*);
        self.columns.clearRetainingCapacity();
        self.wrapped_right = 0;
        const style = c.mdf_text_style(0, 0, 0, false, self.zoom);
        const advance = try self.canvas.measure(.{ .face = 0, .size = style.size, .flags = 0 }, "m");
        c.mdf_viewport_configure(self.viewport, @floatFromInt(self.canvas.logical_width), self.width_mode, advance.width, self.wrap);
        for (0..self.layouts.len) |index| {
            const block = c.mdf_core_block(self.core, index);
            const size = c.mdf_text_style(if (kind(block, "heading")) 1 else if (kind(block, "code")) 2 else 0, block.heading, 0, block.flags & 4 != 0, self.zoom).size;
            geometry.heights[index] = if (!self.visible(index)) 0 else c.mdf_estimate_block(if (kind(block, "rule")) 3 else if (kind(block, "heading")) 1 else 0,
                block.bytes, block.lines, block.indent, block.quote, @floatFromInt(size), self.zoom, fields.content_width, self.wrap);
        }
        if (!c.mdf_viewport_reindex(self.viewport)) return error.OutOfMemory;
        geometry = c.mdf_viewport_view(self.viewport);
        const next = if (geometry.offset_count > 0) geometry.offsets[@min(anchor, self.layouts.len)] + delta else 0;
        c.mdf_viewport_move(self.viewport, next, @floatFromInt(self.canvas.logical_height));
    }
    pub fn toggle(self: *Reader, index: usize) !void {
        if (index >= self.layouts.len or !kind(c.mdf_core_block(self.core, index), "details")) return;
        self.details_open[index] = !self.details_open[index];
        try self.invalidate();
    }
    pub fn refreshImages(self: *Reader) !void {
        const images = self.images orelse return;
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
        var view = c.mdf_viewport_view(self.viewport);
        const anchor = c.mdf_viewport_index_at(self.viewport, fields.scroll, self.layouts.len);
        const delta = if (view.offset_count > 0) fields.scroll - view.offsets[anchor] else 0;
        var indices = images.values.keyIterator();
        while (indices.next()) |key| {
            const index = key.*;
            if (index >= self.layouts.len) continue;
            if (self.layouts[index]) |old| c.mdf_layout_result_free(old);
            self.layouts[index] = null;
            view.heights[index] = c.mdf_layout_result_view(try self.layout(index)).height;
        }
        if (!c.mdf_viewport_reindex(self.viewport)) return error.OutOfMemory;
        view = c.mdf_viewport_view(self.viewport);
        if (view.offset_count > 0) fields.scroll = view.offsets[@min(anchor, self.layouts.len)] + delta;
        self.refreshOverflow();
        c.mdf_viewport_move(self.viewport, fields.scroll, @floatFromInt(self.canvas.logical_height));
    }
    pub fn horizontalTotal(self: *Reader) !f32 {
        const width: f32 = @floatFromInt(self.canvas.logical_width);
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
        if (fields.horizontal_dirty) {
            // Wrapped paragraphs never need a whole-document measurement.
            // Only encountered table/diagram layouts contribute overflow.
            if (self.wrap) {
                c.mdf_viewport_horizontal(self.viewport, width, self.wrapped_right);
                return fields.horizontal_extent;
            }
            var right = width;
            for (0..self.layouts.len) |index| {
                const options = self.layoutOptions(index, false);
                const value = c.mdf_core_layout_block(self.core, index, &options, measure, columnWidths, self) orelse
                    return self.failure orelse error.BlockLayoutFailed;
                const measured = c.mdf_layout_result_view(value);
                if (measured.right > 0) right = @max(right, measured.right + fields.margin);
                c.mdf_layout_result_free(value);
            }
            c.mdf_viewport_horizontal(self.viewport, width, right);
        }
        return fields.horizontal_extent;
    }
    pub fn selected(self: *Reader) []const u8 {
        const selection = self.selection orelse return "";
        const plain = bytes(c.mdf_core_document_text(self.core).text);
        return plain[@min(plain.len, @min(selection.first, selection.last))..@min(plain.len, @max(selection.first, selection.last))];
    }
    pub fn selectAll(self: *Reader) void {
        self.selection = .{ .first = 0, .last = c.mdf_core_document_text(self.core).text.len };
    }
    pub fn hit(self: *Reader, x: f32, y: f32) !?Hit {
        if (self.layouts.len == 0) return null;
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
        const geometry = c.mdf_viewport_view(self.viewport);
        const index = c.mdf_viewport_index_at(self.viewport, y + fields.scroll, self.layouts.len);
        const layout_value = self.layouts[index] orelse return null;
        const view = c.mdf_layout_result_view(layout_value);
        const px = x + fields.horizontal_scroll;
        const py = y + fields.scroll - geometry.offsets[index];
        var distance: f32 = 1e30;
        var best: ?Hit = null;
        if (view.run_count > 0) for (view.runs[0..view.run_count]) |run| {
            if (run.position == std.math.maxInt(usize)) continue;
            const dy = @abs(py - (run.y - @as(f32, @floatFromInt(run.font.size)) * 0.4));
            const dx = if (px < run.x) run.x - px else if (px > run.x + run.width) px - run.x - run.width else 0;
            const d = dy * 20 + dx;
            if (d >= distance) continue;
            distance = d;
            const text = bytes(run.text);
            var at: usize = 0;
            while (at < text.len) {
                const len = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
                const next = @min(at + len, text.len);
                const first = try self.canvas.measure(run.font, text[0..at]);
                const last = try self.canvas.measure(run.font, text[0..next]);
                if (px < run.x + (first.width + last.width) / 2) break;
                at = next;
            }
            best = .{ .position = run.position + at, .block = index,
                .link = if (dy < @as(f32, @floatFromInt(run.font.size)) and dx < 3) bytes(run.link) else "" };
        };
        return best orelse .{ .position = c.mdf_core_document_text(self.core).starts[index], .block = index };
    }
    pub fn pointer(self: *Reader, event: u32, x: f32, y: f32) ![]const u8 {
        if (event == 0) {
            // A release outside the document body may not reach this reader.
            self.diagram_control = false;
            self.diagram_drag = null;
        }
        if (event != 0) {
            if (self.diagram_control) {
                if (event == 2) self.diagram_control = false;
                return "";
            }
            if (self.diagram_drag) |drag| {
                if (event == 1) {
                    c.mdf_viewport_move_horizontal(self.viewport, drag.horizontal + drag.x - x,
                        @max(0, try self.horizontalTotal() - @as(f32, @floatFromInt(self.canvas.logical_width))), false);
                } else self.diagram_drag = null;
                return "";
            }
        } else if (self.diagramAt(x, y)) |target| {
            self.pressed = null;
            self.diagram_focus = target.index;
            if (target.action) |action| {
                try self.zoomDiagram(target.index, action);
                self.diagram_control = true;
            } else if (target.image) {
                self.diagram_drag = .{ .x = x, .horizontal = c.mdf_viewport_fields(self.viewport).*.horizontal_scroll };
            }
            return "";
        } else self.diagram_focus = null;
        const target = try self.hit(x, y) orelse return "";
        if (event == 0) {
            self.pressed = target;
            self.selection = .{ .first = target.position, .last = target.position };
            self.dragging = false;
        } else if (event == 1) {
            if (self.pressed) |pressed| {
                self.dragging = true;
                self.selection = .{ .first = pressed.position, .last = target.position };
            }
        } else if (self.pressed) |pressed| {
            self.pressed = null;
            if (!self.dragging and pressed.block == target.block) {
                if (kind(c.mdf_core_block(self.core, target.block), "details")) try self.toggle(target.block);
                return target.link;
            }
        }
        return "";
    }
    pub fn draw(self: *Reader) !void {
        const timing=profile.begin(self.canvas.profiling,@src(),"Draw native Markdown viewport",0);
        defer timing.end();
        try self.prepare();
        const scroll_fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
        const total = try self.horizontalTotal();
        c.mdf_viewport_move_horizontal(self.viewport, scroll_fields.horizontal_scroll, @max(0, total - @as(f32, @floatFromInt(self.canvas.logical_width))), false);
        self.canvas.clear();
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(self.viewport);
        const geometry = c.mdf_viewport_view(self.viewport);
        var index = c.mdf_viewport_index_at(self.viewport, fields.scroll, self.layouts.len);
        const palette = self.canvas.palette;
        while (index < self.layouts.len and geometry.offsets[index] < fields.scroll + @as(f32, @floatFromInt(self.canvas.logical_height))) : (index += 1) {
            const layout_value = self.layouts[index] orelse continue;
            const view = c.mdf_layout_result_view(layout_value);
            const dy = geometry.offsets[index] - fields.scroll;
            if (view.rect_count > 0) for (view.rects[0..view.rect_count]) |rect|
                self.canvas.rectangle(rect.x - fields.horizontal_scroll, dy + rect.y, rect.width, rect.height, palette.role(rect.role));
            const block = c.mdf_core_block(self.core, index);
            if (view.image) if (self.images) |images| if (images.values.getPtr(index)) |image| {
                self.canvas.image(image.pixels, view.ix - fields.horizontal_scroll, dy + view.iy, view.iw, view.ih);
                if (self.mermaid(index)) |diagram| {
                    const box = self.diagramBox(index);
                    const height = diagrams.Controls.init(box.left, 0, box.width).height;
                    const controls = diagrams.Controls.init(box.left, dy + view.iy - height, box.width);
                    const state = self.diagramState(index);
                    try controls.draw(self.canvas, state, state.factor(box.width, diagram.logical_width * self.zoom), self.diagram_focus == index);
                    const right = controls.boxes[3].x + controls.boxes[3].width;
                    if (height == 32 and right + 96 <= box.left + box.width)
                        try self.canvas.text(.{ .face = 0, .size = 12 }, "Drag to pan", right + 12, dy + view.iy - 12, palette.muted);
                }
            };
            if (kind(block, "details")) {
                const side = @as(f32, @floatFromInt(c.mdf_text_style(0, 0, 0, false, self.zoom).size)) * 0.55;
                const x = fields.margin + @as(f32, @floatFromInt(@min(20, block.indent + block.quote))) * 22 * self.zoom - fields.horizontal_scroll;
                const y = dy + side * 0.7;
                const points: [3][2]f32 = if (self.details_open[index]) .{ .{ x, y }, .{ x + side, y }, .{ x + side / 2, y + side * 0.7 } } else
                    .{ .{ x, y }, .{ x, y + side }, .{ x + side * 0.7, y + side / 2 } };
                try self.canvas.triangle(points, palette.fg);
            }
            if (view.run_count > 0) for (view.runs[0..view.run_count]) |run| {
                const x = run.x - fields.horizontal_scroll;
                const baseline = dy + run.y;
                const top = baseline - (run.font_height - run.font_descent);
                if (run.flags & (4 | 32) != 0)
                    self.canvas.rectangle(x - 1, top - 1, run.width + 2, run.font_height + 2, if (run.flags & 32 != 0) palette.highlight else palette.panel);
                if (self.selection) |selection| {
                    if (run.position != std.math.maxInt(usize)) {
                        const begin = @max(@min(selection.first, selection.last), run.position);
                        const end = @min(@max(selection.first, selection.last), run.position + run.text.len);
                        if (begin < end) {
                            const text = bytes(run.text);
                            const first = try self.canvas.measure(run.font, text[0..begin - run.position]);
                            const last = try self.canvas.measure(run.font, text[0..end - run.position]);
                            self.canvas.rectangle(x + first.width, top, last.width - first.width, run.font_height + 2, palette.selection);
                        }
                    }
                }
                const color = if (run.flags & 32 != 0) palette.fg else if (run.role != 0) palette.role(run.role) else if (run.link.len != 0) palette.link else palette.fg;
                try self.canvas.text(run.font, bytes(run.text), x, baseline, color);
                if (run.flags & 8 != 0)
                    self.canvas.rectangle(@trunc(x), @trunc(baseline - @as(f32, @floatFromInt(run.font.size)) * 0.28), run.width, 1, color);
                if (run.flags & 16 != 0 or run.link.len != 0)
                    self.canvas.rectangle(@trunc(x), @trunc(baseline + 2), run.width, 1, color);
            };
        }
    }
};
