const std = @import("std");
const profile = @import("mdf").profiling;
const a = std.testing.allocator;

test "profiling: disabled recording leaves spans inert" {
    const work = profile.begin(@src(), "disabled", .gui);
    const wait = profile.wait(@src(), "disabled wait");
    try std.testing.expect(work.recorder == null and wait.recorder == null);
    work.end();
    wait.end();
    profile.signal(@src(), "disabled signal", .gui);
}
test "profiling: snapshots stay independent of subsequently recorded events" {
    const recorder = try a.create(profile.Recorder);
    defer a.destroy(recorder);
    try recorder.init(1000);
    defer recorder.deinit();
    recorder.enable();
    profile.external(.gui, .work, "first", "unit", 1, 1100, 20, 0);
    const first = try recorder.snapshot(a);
    defer a.free(first.events);
    profile.external(.gui, .wait, "second", "unit", 2, 1200, 30, 0);
    const second = try recorder.snapshot(a);
    defer a.free(second.events);
    try std.testing.expectEqual(@as(usize, 1), first.events.len);
    try std.testing.expectEqual(@as(usize, 2), second.events.len);
    try std.testing.expectEqual(@as(u64, 100), first.events[0].start_ns);
    try std.testing.expectEqual(@as(u64, 20), first.events[0].duration_ns);
    try std.testing.expectEqual(.wait, second.events[1].kind);
}
test "profiling: a full event buffer counts dropped work without overwriting data" {
    const recorder = try a.create(profile.Recorder);
    defer a.destroy(recorder);
    try recorder.init(0);
    defer recorder.deinit();
    recorder.enable();
    for (0..5000) |i| profile.external(.gui, .work, "bounded", "unit", 1, i, 1, 0);
    const snapshot = try recorder.snapshot(a);
    defer a.free(snapshot.events);
    try std.testing.expectEqual(@as(usize, 4096), snapshot.events.len);
    try std.testing.expectEqual(@as(usize, 904), snapshot.dropped);
    try std.testing.expectEqual(@as(u64, 0), snapshot.events[0].start_ns);
    try std.testing.expectEqual(@as(u64, 4095), snapshot.events[4095].start_ns);
}
test "profiling: nesting on one track does not indent another track" {
    const recorder = try a.create(profile.Recorder);
    defer a.destroy(recorder);
    try recorder.init(profile.nowNs());
    defer recorder.deinit();
    recorder.enable();
    const gui = profile.begin(@src(), "GUI", .gui);
    const nav = profile.begin(@src(), "navigation", .navigation);
    nav.end();
    gui.end();
    const snapshot = try recorder.snapshot(a);
    defer a.free(snapshot.events);
    try std.testing.expectEqual(@as(usize, 2), snapshot.events.len);
    for (snapshot.events) |event| try std.testing.expectEqual(@as(usize, 0), event.depth);
    for (recorder.depths) |depth| try std.testing.expectEqual(@as(usize, 0), depth);
}
test "profiling: allocation failure while taking a snapshot releases its lock" {
    const recorder = try a.create(profile.Recorder);
    defer a.destroy(recorder);
    try recorder.init(0);
    defer recorder.deinit();
    recorder.enable();
    profile.external(.gui, .work, "preserved", "unit", 1, 1, 1, 0);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, recorder.snapshot(failing.allocator()));
    const snapshot = try recorder.snapshot(a);
    defer a.free(snapshot.events);
    try std.testing.expectEqualStrings("preserved", snapshot.events[0].name);
}
