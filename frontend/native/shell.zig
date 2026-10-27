//! Native toolbar, outline, minimap and scroll chrome.
const std = @import("std");
const c = @import("native");
const paint = @import("canvas.zig");
const document = @import("reader.zig");
pub const preferences = @import("settings");
pub const menus = @import("menu.zig");
pub const window_frame = @import("frame.zig");
pub const scaling = @import("scale-policy.zig");
pub const minimap = @import("minimap.zig");
pub const directory=@import("directory.zig");
pub const diagrams = document.diagrams;
pub const Box=struct{x:i32,y:i32,width:i32,height:i32};
pub const FileHit=union(enum){none,path,parent,home,hidden,open,cancel,row:usize,scroll:f32};
pub const PathMove=enum{left,right,home,end};
pub const Action = enum { none, toc, theme, width, smaller, reset, larger, wrap, preview };
pub const Layout = struct { left: i32, right: i32, x: i32, y: i32 = 74, width: i32, height: i32, view_height: i32 };
pub fn thumbHeight(view_height: i32) i32 {
    const track_h=@max(1,view_height-40);
    return @min(track_h,@max(12,@as(i32,@intFromFloat(@round(@as(f32,@floatFromInt(track_h))*0.1)))));
}
pub const Shell = struct {
    toc: bool = true,
    preview: bool = true,
    dark: bool = false,
    wrap: bool = true,
    horizontal_overflow: bool = false,
    points: i32 = 12,
    width_mode: u32 = 1,
    toc_scroll: usize = 0,
    theme: preferences.Preset = .classic,
    reload: bool = true,
    save: bool = false,
    menu: menus.Menu = .{},
    modal: enum { none, open, about, licenses } = .none,
    path: [4096]u8 = @splat(0),
    path_len: usize = 0,
    path_selected: bool = false,
    path_cursor: usize = 0,
    path_anchor: ?usize = null,
    path_first: usize = 0,
    status: [256]u8 = @splat(0),
    status_len: usize = 0,
    preview_atlas: ?*const minimap.Atlas = null,
    files:?*const directory.Listing=null,
    file_first:usize=0,
    file_selected:?usize=null,
    file_focus:bool=false,
    file_hidden:bool=false,
    file_loading:bool=false,
    file_message:[]const u8="",

    pub fn load(self: *Shell, value: preferences.Values) void {
        self.toc = value.show_toc; self.preview = value.show_preview;
        self.dark = value.dark_mode; self.wrap = value.line_wrap;
        self.points = std.math.clamp(value.font_size, 8, 72);
        self.width_mode = switch (value.max_width) { .characters_100 => 0, .percent_80 => 1, .percent_100 => 2 };
        self.theme = value.theme; self.reload = value.auto_reload; self.save = value.save_settings_across_sessions;
    }
    pub fn values(self: *const Shell, window: preferences.Window) preferences.Values {
        return .{ .show_toc = self.toc, .show_preview = self.preview, .dark_mode = self.dark, .line_wrap = self.wrap,
            .font_size = @intCast(self.points), .max_width = switch (self.width_mode) { 0 => .characters_100, 2 => .percent_100, else => .percent_80 },
            .theme = self.theme, .auto_reload = self.reload, .save_settings_across_sessions = self.save, .window = window };
    }
    pub fn message(self: *Shell, value: []const u8) void {
        self.status_len = @min(value.len, self.status.len);
        while (self.status_len < value.len and self.status_len > 0 and value[self.status_len] & 0xc0 == 0x80) self.status_len -= 1;
        @memcpy(self.status[0..self.status_len], value[0..self.status_len]);
    }
    pub fn openDialog(self: *Shell, path: []const u8) void {
        self.modal = .open;
        self.path_len = @min(path.len, self.path.len);
        while (self.path_len < path.len and self.path_len > 0 and path[self.path_len] & 0xc0 == 0x80) self.path_len -= 1;
        @memcpy(self.path[0..self.path_len], path[0..self.path_len]);
        self.path_cursor=self.path_len;self.path_anchor=null;self.path_first=0;
        self.path_selected = true;
    }
    pub fn pathRange(self:*const Shell) ?struct{first:usize,last:usize} {
        if(self.path_selected and self.path_len>0) return .{.first=0,.last=self.path_len};
        const anchor=@min(self.path_anchor orelse return null,self.path_len);
        const cursor=@min(self.path_cursor,self.path_len);
        return if(anchor==cursor) null else .{.first=@min(anchor,cursor),.last=@max(anchor,cursor)};
    }
    pub fn selectedPath(self:*const Shell) []const u8 {
        const range=self.pathRange() orelse return "";
        return self.path[range.first..range.last];
    }
    pub fn selectPath(self:*Shell) void {
        self.path_selected=true;self.path_cursor=self.path_len;self.path_anchor=0;
    }
    fn previousPath(self:*const Shell,position:usize) usize {
        var result=@min(position,self.path_len)-|1;
        while(result>0 and self.path[result]&0xc0==0x80) result-=1;
        return result;
    }
    fn nextPath(self:*const Shell,position:usize) usize {
        var result=@min(self.path_len,position+1);
        while(result<self.path_len and self.path[result]&0xc0==0x80) result+=1;
        return result;
    }
    fn erasePath(self:*Shell,first:usize,last:usize) void {
        std.mem.copyForwards(u8,self.path[first..self.path_len-(last-first)],self.path[last..self.path_len]);
        self.path_len-=last-first;self.path_cursor=first;self.path_anchor=null;self.path_selected=false;
        self.path_first=@min(self.path_first,first);
    }
    pub fn movePath(self:*Shell,direction:PathMove,extend:bool) void {
        const old=@min(self.path_cursor,self.path_len);
        const range=self.pathRange();
        if(extend) {
            if(self.path_selected) self.path_anchor=0 else if(self.path_anchor==null) self.path_anchor=old;
        } else self.path_anchor=null;
        self.path_cursor=switch(direction) {
            .home=>0,.end=>self.path_len,
            .left=>if(!extend and range!=null) range.?.first else self.previousPath(old),
            .right=>if(!extend and range!=null) range.?.last else self.nextPath(old),
        };
        self.path_selected=false;
    }
    pub fn insertPath(self: *Shell, text: []const u8) void {
        const range=self.pathRange();
        const first=if(range) |value| value.first else @min(self.path_cursor,self.path_len);
        const last=if(range) |value| value.last else first;
        if (text.len == 0 or text.len > self.path.len - (self.path_len-(last-first)) or !std.unicode.utf8ValidateSlice(text)) return;
        for (text) |byte| if (byte < 32 or byte == 127) return;
        if(text.len>=last-first) std.mem.copyBackwards(u8,self.path[first+text.len..][0..self.path_len-last],self.path[last..self.path_len])
        else std.mem.copyForwards(u8,self.path[first+text.len..][0..self.path_len-last],self.path[last..self.path_len]);
        @memcpy(self.path[first..][0..text.len],text);
        self.path_len=self.path_len-(last-first)+text.len;
        self.path_cursor=first+text.len;self.path_anchor=null;self.path_selected=false;
        self.path_first=@min(self.path_first,first);
    }
    pub fn backspacePath(self: *Shell) void {
        if(self.pathRange()) |range| self.erasePath(range.first,range.last)
        else if(self.path_cursor>0) self.erasePath(self.previousPath(self.path_cursor),@min(self.path_cursor,self.path_len));
    }
    pub fn deletePath(self:*Shell) void {
        if(self.pathRange()) |range| self.erasePath(range.first,range.last)
        else if(self.path_cursor<self.path_len) self.erasePath(self.path_cursor,self.nextPath(self.path_cursor));
    }
    fn pathView(self:*Shell,canvas:*paint.Canvas,width:f32) !struct{first:usize,last:usize} {
        const cursor=@min(self.path_cursor,self.path_len);
        self.path_first=@min(self.path_first,cursor);
        while(self.path_first<cursor and (try canvas.measure(.{.face=0,.size=16,.flags=0},self.path[self.path_first..cursor])).width>width)
            self.path_first=self.nextPath(self.path_first);
        while(self.path_first>0) {
            const previous=self.previousPath(self.path_first);
            if((try canvas.measure(.{.face=0,.size=16,.flags=0},self.path[previous..cursor])).width>width) break;
            self.path_first=previous;
        }
        var last=self.path_len;
        while(last>self.path_first and (try canvas.measure(.{.face=0,.size=16,.flags=0},self.path[self.path_first..last])).width>width)
            last=self.previousPath(last);
        return .{.first=self.path_first,.last=last};
    }
    pub fn pointPath(self:*Shell,canvas:*paint.Canvas,x:f32,width:f32,extend:bool) !void {
        const view=try self.pathView(canvas,width);
        var position=view.first;var previous:f32=0;
        while(position<view.last) {
            const next=self.nextPath(position);
            const right=(try canvas.measure(.{.face=0,.size=16,.flags=0},self.path[view.first..next])).width;
            if(x<(previous+right)/2) break;
            position=next;previous=right;
        }
        if(x<0 and view.first>0) position=self.previousPath(view.first);
        if(x>width and view.last<self.path_len) position=self.nextPath(view.last);
        if(extend) {if(self.path_anchor==null) self.path_anchor=self.path_cursor;} else self.path_anchor=null;
        self.path_cursor=position;self.path_selected=false;
    }

    pub fn horizontalVisible(self: *const Shell) bool {
        return !self.wrap or self.horizontal_overflow;
    }
    pub fn layout(self: *const Shell, width: i32, height: i32) Layout {
        const left: i32 = if (self.toc) @min(220, @as(i32, @intFromFloat(@as(f32, @floatFromInt(width)) * 0.22))) else 0;
        const right: i32 = if (self.preview) @min(130, @as(i32, @intFromFloat(@as(f32, @floatFromInt(width)) * 0.12))) else 0;
        const view_height = @max(1, height - 74 - 24);
        return .{ .left = left, .right = right, .x = left, .width = @max(1, width - left - right - 20),
            .height = @max(1, view_height - (if (self.horizontalVisible()) @as(i32, 20) else 0)), .view_height = view_height };
    }
    pub fn actionAt(_: *const Shell, x: f32, y: f32, width: i32) Action {
        if (y < 35 or y >= 67) return .none;
        if (x >= 10 and x < 46) return .toc;
        if (x >= 53 and x < 89) return .theme;
        if (x >= 96 and x < 160) return .width;
        if (x >= 174 and x < 206) return .smaller;
        if (x >= 213 and x < 245) return .reset;
        if (x >= 252 and x < 284) return .larger;
        if (x >= 298 and x < 326) return .wrap;
        if (x >= @as(f32, @floatFromInt(width - 90)) and x < @as(f32, @floatFromInt(width - 10))) return .preview;
        return .none;
    }
    pub fn apply(self: *Shell, action: Action) void {
        switch (action) {
            .toc => self.toc = !self.toc,
            .theme => self.dark = !self.dark,
            .width => self.width_mode = if (self.width_mode == 2) 1 else 2,
            .smaller => self.points = @max(8, self.points - 1),
            .reset => self.points = self.theme.fontSize(),
            .larger => self.points = @min(72, self.points + 1),
            .wrap => self.wrap = !self.wrap,
            .preview => self.preview = !self.preview,
            .none => {},
        }
    }
    fn label(canvas: *paint.Canvas, value: []const u8, x: f32, y: f32, size: i32, bold: bool, color: u32) !void {
        try canvas.text(.{ .face = @intFromBool(bold), .size = size, .flags = 0 }, value, x, y, color);
    }
    fn button(canvas: *paint.Canvas, value: []const u8, x: i32, width: i32, selected: bool, size: i32) !void {
        const palette = canvas.palette;
        canvas.rectangle(@floatFromInt(x), 35, @floatFromInt(width), 32, palette.border);
        canvas.rectangle(@floatFromInt(x + 1), 36, @floatFromInt(width - 2), 30, if (selected) 0x3276b0 else palette.panel);
        const style: paint.FontSpec = .{ .face = 0, .size = size, .flags = 0 };
        const metrics = try canvas.measure(style, value);
        try canvas.text(style, value, @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(width)) - metrics.width) / 2,
            35 + (32 - metrics.height) / 2 + metrics.height - metrics.descent, if (selected) 0xffffff else palette.fg);
    }
    fn headingTitle(core: *c.MdfCore, index: usize, allocator: std.mem.Allocator) ![]u8 {
        const block = c.mdf_core_block(core, index);
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);
        for (0..block.spans) |span| try text.appendSlice(allocator, document.bytes(c.mdf_core_span(core, index, -1, span).text));
        return text.toOwnedSlice(allocator);
    }
    fn clipped(canvas: *paint.Canvas, value: []const u8, maximum: f32, size: i32) ![]const u8 {
        const style: paint.FontSpec = .{ .face = 0, .size = size, .flags = 0 };
        var end = value.len;
        while (end > 0 and (try canvas.measure(style, value[0..end])).width > maximum) {
            end -= 1;
            while (end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
        }
        return value[0..end];
    }
    pub fn draw(self: *Shell, canvas: *paint.Canvas, content: *document.Reader) !void {
        const w = canvas.logical_width;
        const h = canvas.logical_height;
        const bounds = self.layout(w, h);
        const palette = canvas.palette;
        canvas.clear();
        canvas.rectangle(0, 0, @floatFromInt(w), 74, palette.panel);
        try label(canvas, "File", 12, 19, 14, false, palette.fg);
        try label(canvas, "View", 56, 19, 14, false, palette.fg);
        try label(canvas, "Font", 106, 19, 14, false, palette.fg);
        try label(canvas, "Theme", 152, 19, 14, false, palette.fg);
        try label(canvas, "Settings", 217, 19, 14, false, palette.fg);
        try label(canvas, "Help", 292, 19, 14, false, palette.fg);
        try button(canvas, "TOC", 10, 36, self.toc, 12);
        try button(canvas, if (self.dark) "Dark" else "Light", 53, 36, self.dark, 11);
        try button(canvas, switch (self.width_mode) { 0 => "100ch", 1 => "80%", else => "100%" }, 96, 64, false, 14);
        canvas.rectangle(167, 40, 1, 22, palette.border);
        try button(canvas, "A-", 174, 32, false, 16);
        try button(canvas, "A0", 213, 32, false, 15);
        try button(canvas, "A+", 252, 32, false, 16);
        canvas.rectangle(291, 40, 1, 22, palette.border);
        try button(canvas, "NW", 298, 28, !self.wrap, 11);
        try button(canvas, "Preview", w - 90, 80, self.preview, 16);
        canvas.blit(content.canvas, bounds.x, bounds.y);
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(content.viewport);
        const geometry = c.mdf_viewport_view(content.viewport);
        if (self.toc) {
            canvas.rectangle(0, 74, @floatFromInt(bounds.left), @floatFromInt(bounds.view_height), palette.panel);
            try label(canvas, "Contents", 14, 101, 18, true, palette.fg);
            var row: usize = 0;
            for (0..content.layouts.len) |index| {
                const block = c.mdf_core_block(content.core, index);
                if (!std.mem.eql(u8, document.bytes(block.kind), "heading")) continue;
                defer row += 1;
                if (row < self.toc_scroll) continue;
                const y = @as(i32, @intCast(row - self.toc_scroll)) * 26 + 132;
                if (y > 74 + bounds.view_height) break;
                const value = try headingTitle(content.core, index, canvas.allocator);
                defer canvas.allocator.free(value);
                const x: f32 = 14 + @as(f32, @floatFromInt(@min(5, block.heading -| 1))) * 12;
                const visible = try clipped(canvas, value, @as(f32, @floatFromInt(bounds.left)) - x - 12, 16);
                try label(canvas, visible, x, @floatFromInt(y), 16, false, palette.fg);
            }
        }
        const track_y = 94;
        const track_h = @max(1, bounds.view_height - 40);
        const thumb_h = thumbHeight(bounds.view_height);
        const maximum = @max(0, c.mdf_viewport_total(content.viewport) - @as(f32, @floatFromInt(bounds.height)));
        const fraction = if (maximum > 0) std.math.clamp(fields.scroll / maximum, 0, 1) else 0;
        const thumb_y = track_y + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(track_h - thumb_h)) * fraction)));
        const scrollbar_x = bounds.x + bounds.width;
        canvas.rectangle(@floatFromInt(scrollbar_x), 74, 20, @floatFromInt(bounds.view_height), palette.panel);
        canvas.rectangle(@floatFromInt(scrollbar_x + 2), @floatFromInt(thumb_y), 16, @floatFromInt(thumb_h), palette.border);
        try label(canvas, "^", @floatFromInt(scrollbar_x + 5), 89, 14, false, palette.fg);
        try label(canvas, "v", @floatFromInt(scrollbar_x + 5), @floatFromInt(74 + bounds.view_height - 5), 14, false, palette.fg);
        if (self.preview) {
            const map_x = w - bounds.right;
            canvas.rectangle(@floatFromInt(map_x), 74, @floatFromInt(bounds.right), @floatFromInt(bounds.view_height), palette.panel);
            const total = @max(1, c.mdf_viewport_total(content.viewport));
            const atlas_drawn = if (self.preview_atlas) |atlas| atlas.draw(canvas,map_x,track_y,bounds.right,track_h,
                if (geometry.offset_count > 0) geometry.offsets[0..geometry.offset_count] else &.{},
                if (geometry.count > 0) geometry.heights[0..geometry.count] else &.{},total) else false;
            if (!atlas_drawn) for (0..content.layouts.len) |index| {
                const block = c.mdf_core_block(content.core, index);
                if (geometry.heights[index] <= 0) continue;
                const y = track_y + geometry.offsets[index] / total * @as(f32, @floatFromInt(track_h));
                const width = @min(@as(f32, @floatFromInt(bounds.right - 6)), @max(4, @as(f32, @floatFromInt(block.bytes)) * 0.35));
                canvas.rectangle(@floatFromInt(map_x + 3), y, width, 1, if (self.dark) 0x7a828e else 0xb0b7c1);
            };
            canvas.overlay(map_x, thumb_y, bounds.right, thumb_h, 0x3276b0, 40);
            canvas.rectangle(@floatFromInt(map_x), @floatFromInt(thumb_y), @floatFromInt(bounds.right), 1, 0x8bb7dd);
            canvas.rectangle(@floatFromInt(map_x), @floatFromInt(thumb_y + thumb_h - 1), @floatFromInt(bounds.right), 1, 0x8bb7dd);
        }
        if (self.horizontalVisible()) {
            canvas.rectangle(@floatFromInt(bounds.x), @floatFromInt(74 + bounds.height), @floatFromInt(bounds.width), 20, palette.panel);
            const track: f32 = @floatFromInt(@max(1, bounds.width - 40));
            const total = @max(@as(f32, @floatFromInt(bounds.width)), fields.horizontal_extent);
            const thumb = @min(track, @max(20, track * @as(f32, @floatFromInt(bounds.width)) / total));
            const maximum_x = @max(0, total - @as(f32, @floatFromInt(bounds.width)));
            const offset = if (maximum_x > 0) (track - thumb) * fields.horizontal_scroll / maximum_x else 0;
            canvas.rectangle(@as(f32, @floatFromInt(bounds.x + 20)) + offset, @floatFromInt(76 + bounds.height), thumb, 16, palette.border);
            try label(canvas, "<", @floatFromInt(bounds.x + 5), @floatFromInt(89 + bounds.height), 14, false, palette.fg);
            try label(canvas, ">", @floatFromInt(bounds.x + bounds.width - 15), @floatFromInt(89 + bounds.height), 14, false, palette.fg);
        }
        canvas.rectangle(0, @floatFromInt(h - 24), @floatFromInt(w), 24, palette.panel);
        const status = if (self.status_len > 0) self.status[0..self.status_len] else "Markdown FAST";
        try label(canvas, try clipped(canvas, status, @floatFromInt(w - 24), 13), 12, @floatFromInt(h - 7), 13, false, palette.muted);
        try self.drawMenu(canvas);
        try self.drawModal(canvas);
    }
    fn checked(self: *const Shell, command: menus.Command) bool {
        return switch (command) { .toc => self.toc, .preview => self.preview, .wrap => self.wrap,
            .width80 => self.width_mode == 1, .width100 => self.width_mode == 2,
            .size => |size| self.points == size, .theme => |theme| self.theme == theme,
            .auto_reload => self.reload, .save_settings => self.save, else => false };
    }
    fn drawMenu(self: *Shell, canvas: *paint.Canvas) !void {
        self.menu.fit(canvas.logical_width, canvas.logical_height);
        const title = self.menu.opened orelse return;
        const box = self.menu.bounds(canvas.logical_width, canvas.logical_height);
        const palette = canvas.palette;
        canvas.rectangle(@floatFromInt(box.x), 28, @floatFromInt(box.width), @floatFromInt(box.rows * 26 + 8), palette.border);
        canvas.rectangle(@floatFromInt(box.x + 1), 29, @floatFromInt(box.width - 2), @floatFromInt(box.rows * 26 + 6), palette.panel);
        const rows = menus.items(title);
        for (0..box.rows) |row| {
            const index = row + self.menu.first;
            const y: f32 = @floatFromInt(32 + row * 26);
            const selected = index == self.menu.selected;
            if (selected) canvas.rectangle(@floatFromInt(box.x + 2), y, @floatFromInt(box.width - 4), 26, palette.selection);
            if (self.checked(rows[index].command)) try label(canvas, "*", @floatFromInt(box.x + 8), y + 18, 14, true, palette.fg);
            try label(canvas, rows[index].name, @floatFromInt(box.x + 24), y + 18, 14, false, palette.fg);
            if (rows[index].shortcut.len > 0) {
                const metrics = try canvas.measure(.{ .face = 0, .size = 12, .flags = 0 }, rows[index].shortcut);
                try label(canvas, rows[index].shortcut, @as(f32, @floatFromInt(box.x + box.width - 10)) - metrics.width, y + 18, 12, false, palette.muted);
            }
        }
    }
    pub fn modalBox(width: i32, height: i32) Box {
        const w = @max(1, @min(620, width - 32));
        const h = @max(1, @min(226, height - 32));
        return .{ .x = @divTrunc(width - w, 2), .y = @divTrunc(height - h, 2), .width = w, .height = h };
    }
    pub fn fileBox(width:i32,height:i32) Box {
        const w=@max(1,@min(620,width-32));
        const h=@max(1,@min(500,height-48));
        return .{.x=@divTrunc(width-w,2),.y=32+@divTrunc(height-32-h,2),.width=w,.height=h};
    }
    pub fn fileRows(width:i32,height:i32) usize {
        return @intCast(@max(0,@divTrunc(fileBox(width,height).height-190,24)));
    }
    pub fn fileHit(self:*const Shell,x:f32,y:f32,width:i32,height:i32) FileHit {
        const box=fileBox(width,height);
        const px=x-@as(f32,@floatFromInt(box.x));const py=y-@as(f32,@floatFromInt(box.y));
        const w:@TypeOf(px)=@floatFromInt(box.width);const h:@TypeOf(py)=@floatFromInt(box.height);
        if(px<0 or py<0 or px>=w or py>=h) return .none;
        if(py>=62 and py<96 and px>=20 and px<w-20) return .path;
        if(py>=106 and py<132) {
            if(px>=20 and px<96) return .parent;
            if(px>=104 and px<180) return .home;
            if(px>=188 and px<292) return .hidden;
        }
        if(py>=h-48 and py<h-18) {
            if(px>=w-106 and px<w-20) return .open;
            if(px>=w-204 and px<w-118) return .cancel;
        }
        const rows=fileRows(width,height);
        const count=if(self.files) |files| files.entries.len else 0;
        if(rows==0 or py<140 or py>=140+@as(f32,@floatFromInt(rows*24)) or px<20 or px>=w-20) return .none;
        if(count>rows and px>=w-36) return .{.scroll=std.math.clamp((py-140)/@as(f32,@floatFromInt(rows*24)),0,1)};
        const index=self.file_first+@as(usize,@intFromFloat((py-140)/24));
        return if(index<count) .{.row=index} else .none;
    }
    fn fileLabel(canvas:*paint.Canvas,text:[]const u8,x:f32,y:f32,width:f32,size:i32) !void {
        if((try canvas.measure(.{.face=0,.size=size,.flags=0},text)).width<=width) return label(canvas,text,x,y,size,false,canvas.palette.fg);
        const suffix=try canvas.measure(.{.face=0,.size=size,.flags=0},"...");
        const visible=try clipped(canvas,text,width-suffix.width,size);
        try label(canvas,visible,x,y,size,false,canvas.palette.fg);
        try label(canvas,"...",x+(try canvas.measure(.{.face=0,.size=size,.flags=0},visible)).width,y,size,false,canvas.palette.fg);
    }
    fn fileButton(canvas:*paint.Canvas,text:[]const u8,x:i32,y:i32,width:i32,selected:bool) !void {
        const palette=canvas.palette;
        canvas.rectangle(@floatFromInt(x),@floatFromInt(y),@floatFromInt(width),26,palette.border);
        canvas.rectangle(@floatFromInt(x+1),@floatFromInt(y+1),@floatFromInt(width-2),24,if(selected) 0x3276b0 else palette.bg);
        try label(canvas,text,@floatFromInt(x+10),@floatFromInt(y+18),13,false,if(selected) 0xffffff else palette.fg);
    }
    fn drawFileModal(self:*Shell,canvas:*paint.Canvas) !void {
        const box=fileBox(canvas.logical_width,canvas.logical_height);const palette=canvas.palette;
        canvas.overlay(0,0,canvas.logical_width,canvas.logical_height,0,80);
        canvas.rectangle(@floatFromInt(box.x),@floatFromInt(box.y),@floatFromInt(box.width),@floatFromInt(box.height),palette.border);
        canvas.rectangle(@floatFromInt(box.x+1),@floatFromInt(box.y+1),@floatFromInt(box.width-2),@floatFromInt(box.height-2),palette.panel);
        try label(canvas,"Open Markdown",@floatFromInt(box.x+20),@floatFromInt(box.y+32),20,true,palette.fg);
        try label(canvas,"Path",@floatFromInt(box.x+20),@floatFromInt(box.y+53),13,false,palette.muted);
        canvas.rectangle(@floatFromInt(box.x+20),@floatFromInt(box.y+62),@floatFromInt(box.width-40),34,palette.border);
        canvas.rectangle(@floatFromInt(box.x+21),@floatFromInt(box.y+63),@floatFromInt(box.width-42),32,palette.bg);
        const visible=try self.pathView(canvas,@floatFromInt(box.width-56));
        if(!self.file_focus) {
            if(self.pathRange()) |selection| {
                const first=@max(visible.first,selection.first);const last=@min(visible.last,selection.last);
                if(last>first) {
                    const left=(try canvas.measure(.{.face=0,.size=16,.flags=0},self.path[visible.first..first])).width;
                    const right=(try canvas.measure(.{.face=0,.size=16,.flags=0},self.path[visible.first..last])).width;
                    canvas.rectangle(@as(f32,@floatFromInt(box.x+28))+left,@floatFromInt(box.y+63),right-left,32,palette.selection);
                }
            } else {
                const caret=(try canvas.measure(.{.face=0,.size=16,.flags=0},self.path[visible.first..@min(self.path_cursor,visible.last)])).width;
                canvas.rectangle(@as(f32,@floatFromInt(box.x+28))+caret,@floatFromInt(box.y+69),1,20,palette.fg);
            }
        }
        try label(canvas,self.path[visible.first..visible.last],@floatFromInt(box.x+28),@floatFromInt(box.y+85),16,false,palette.fg);
        try fileButton(canvas,"Parent",box.x+20,box.y+106,76,false);
        try fileButton(canvas,"Home",box.x+104,box.y+106,76,false);
        try fileButton(canvas,"Hidden",box.x+188,box.y+106,104,self.file_hidden);
        const rows=fileRows(canvas.logical_width,canvas.logical_height);
        if(rows>0) {
            canvas.rectangle(@floatFromInt(box.x+20),@floatFromInt(box.y+140),@floatFromInt(box.width-40),@floatFromInt(rows*24),palette.bg);
            if(self.files) |files| {
                const count=files.entries.len;
                const first=@min(self.file_first,count);
                for(first..@min(count,first+rows)) |index| {
                    const top=box.y+140+@as(i32,@intCast(index-first))*24;
                    if(self.file_selected==index) canvas.rectangle(@floatFromInt(box.x+21),@floatFromInt(top),@floatFromInt(box.width-42),24,palette.selection);
                    const entry=files.entries[index];
                    if(entry.directory) try label(canvas,"/",@floatFromInt(box.x+28),@floatFromInt(top+17),14,true,palette.link);
                    try fileLabel(canvas,entry.name,@floatFromInt(box.x+44),@floatFromInt(top+17),@floatFromInt(box.width-88),14);
                }
                if(count>rows) {
                    const track:@TypeOf(@as(f32,0))=@floatFromInt(rows*24);
                    const thumb=@max(12,track*@as(f32,@floatFromInt(rows))/@as(f32,@floatFromInt(count)));
                    const offset=(track-thumb)*@as(f32,@floatFromInt(@min(self.file_first,count-rows)))/@as(f32,@floatFromInt(count-rows));
                    canvas.rectangle(@floatFromInt(box.x+box.width-30),@as(f32,@floatFromInt(box.y+140))+offset,8,thumb,palette.muted);
                }
                if(count==0) try label(canvas,"Empty directory",@floatFromInt(box.x+28),@floatFromInt(box.y+162),14,false,palette.muted);
            }
            if(self.file_loading) try label(canvas,"Loading directory...",@floatFromInt(box.x+28),@floatFromInt(box.y+162),14,false,palette.muted);
        }
        const notice=if(self.file_message.len>0) self.file_message else if(self.files) |files| (if(files.truncated) "Showing the first 10,000 entries" else "") else "";
        if(notice.len>0) try fileLabel(canvas,notice,@floatFromInt(box.x+20),@floatFromInt(box.y+box.height-57),@floatFromInt(box.width-40),12);
        try label(canvas,"Ctrl+L: path",@floatFromInt(box.x+20),@floatFromInt(box.y+box.height-27),12,false,palette.muted);
        try fileButton(canvas,"Cancel",box.x+box.width-204,box.y+box.height-48,86,false);
        try fileButton(canvas,"Open",box.x+box.width-106,box.y+box.height-48,86,true);
    }
    fn drawModal(self: *Shell, canvas: *paint.Canvas) !void {
        if (self.modal == .none) return;
        if(self.modal==.open) return self.drawFileModal(canvas);
        const palette = canvas.palette;
        const box = modalBox(canvas.logical_width, canvas.logical_height);
        canvas.overlay(0, 0, canvas.logical_width, canvas.logical_height, 0, 80);
        canvas.rectangle(@floatFromInt(box.x), @floatFromInt(box.y), @floatFromInt(box.width), @floatFromInt(box.height), palette.border);
        canvas.rectangle(@floatFromInt(box.x + 1), @floatFromInt(box.y + 1), @floatFromInt(box.width - 2), @floatFromInt(box.height - 2), palette.panel);
        try label(canvas, if(self.modal==.about) "About Markdown FAST" else "Third-party licenses",
            @floatFromInt(box.x + 20), @floatFromInt(box.y + 34), 20, true, palette.fg);
        const lines: []const []const u8 = if (self.modal == .about) &.{ "Markdown FAST " ++ @import("app_version").value, "Zig, Wayland and z2d", "github.com/mariobaldini/mdf" }
            else &.{ "License notices are included in the executable.", "Run mdf --licenses to read the full notices." };
        for (lines, 0..) |line, row| try label(canvas, line, @floatFromInt(box.x + 20), @floatFromInt(box.y + 70 + @as(i32, @intCast(row)) * 26), 14, false, palette.fg);
        canvas.rectangle(@floatFromInt(box.x + box.width - 106), @floatFromInt(box.y + box.height - 48), 86, 30, 0x3276b0);
        try label(canvas, "Close", @floatFromInt(box.x + box.width - 90), @floatFromInt(box.y + box.height - 27), 16, false, 0xffffff);
    }
    pub fn headingAt(self: *const Shell, core: *c.MdfCore, x: f32, y: f32, width: i32, height: i32) ?usize {
        const bounds = self.layout(width, height);
        if (!self.toc or x < 0 or x >= @as(f32, @floatFromInt(bounds.left)) or y < 110) return null;
        const target = @as(usize, @intFromFloat((y - 110) / 26)) + self.toc_scroll;
        var row: usize = 0;
        const count = c.mdf_core_document_text(core).count;
        for (0..count) |index| {
            const block = c.mdf_core_block(core, index);
            if (!std.mem.eql(u8, document.bytes(block.kind), "heading")) continue;
            if (row == target) return index;
            row += 1;
        }
        return null;
    }
    pub fn scrollAt(self: *const Shell, content: *document.Reader, x: f32, y: f32, width: i32, height: i32) bool {
        const bounds = self.layout(width, height);
        if (x < @as(f32, @floatFromInt(bounds.x + bounds.width)) or y < 74 or y >= @as(f32, @floatFromInt(74 + bounds.view_height))) return false;
        const track_h = @max(1, bounds.view_height - 40);
        const thumb_h = thumbHeight(bounds.view_height);
        const fraction = std.math.clamp((y - 94 - @as(f32, @floatFromInt(thumb_h)) / 2) / @as(f32, @floatFromInt(@max(1, track_h - thumb_h))), 0, 1);
        const maximum = @max(0, c.mdf_viewport_total(content.viewport) - @as(f32, @floatFromInt(bounds.height)));
        c.mdf_viewport_move(content.viewport, fraction * maximum, @floatFromInt(bounds.height));
        return true;
    }
    pub fn horizontalAt(self: *const Shell, content: *document.Reader, x: f32, y: f32, width: i32, height: i32) bool {
        const bounds = self.layout(width, height);
        if (!self.horizontalVisible() or x < @as(f32, @floatFromInt(bounds.x)) or x >= @as(f32, @floatFromInt(bounds.x + bounds.width)) or
            y < @as(f32, @floatFromInt(74 + bounds.height)) or y >= @as(f32, @floatFromInt(94 + bounds.height))) return false;
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(content.viewport);
        const track: f32 = @floatFromInt(@max(1, bounds.width - 40));
        const total = @max(@as(f32, @floatFromInt(bounds.width)), fields.horizontal_extent);
        const thumb = @min(track, @max(20, track * @as(f32, @floatFromInt(bounds.width)) / total));
        const fraction = std.math.clamp((x - @as(f32, @floatFromInt(bounds.x + 20)) - thumb / 2) / @max(1, track - thumb), 0, 1);
        c.mdf_viewport_move_horizontal(content.viewport, fraction * @max(0, total - @as(f32, @floatFromInt(bounds.width))),
            @max(0, total - @as(f32, @floatFromInt(bounds.width))), false);
        return true;
    }
};
