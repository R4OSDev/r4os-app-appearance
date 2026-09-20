const std = @import("std");
const r4os = @import("r4os");
const policy = @import("graphics_policy.zig");
const status = r4os.graphics_status;
const a = r4os.abi;
const face = r4os.gui.default_palette.face;
const Button = enum { policy, save, refresh, back };

pub fn run(sys: r4os.r4sys.Context, desk: r4os.r4desk.Context, draw: r4os.r4draw.Context) bool {
    var app: App = .{ .sys = sys, .desk = desk, .draw = draw, .dev = r4os.r4dev.Context.fromProgram(sys.base) };
    app.loadPolicy(); _ = app.poll();
    _ = desk.guiSetTitle("Graphics driver"); _ = desk.guiSetMinSize(480, 420);
    app.metrics(); app.render();
    var events = r4os.EventLoop.init(sys, desk, &.{});
    while (!app.exiting and !sys.programShouldClose()) {
        var redraw = true;
        switch (events.wait(r4os.time_contract.timeoutFinite(.{ .nanoseconds = std.time.ns_per_s }))) {
            .message => |message| if (message.guiEvent()) |event| switch (@as(a.GuiEventKind, @enumFromInt(event.kind))) {
                .close => { app.exiting = true; app.close_window = true; },
                .resize => app.metrics(),
                .key_down => app.key(@intCast(event.key & 255)),
                .mouse_down => { app.pressed = app.hit(event.x, event.y); if (app.pressed) |b| app.focus = b; },
                .mouse_up => { const b = app.hit(event.x, event.y); if (b != null and b == app.pressed) app.activate(b.?); app.pressed = null; },
                else => {},
            },
            .timed_out => redraw = false,
            .failure => return true,
        }
        redraw = app.poll() or redraw;
        if (!app.exiting and (redraw or app.paint_failed)) app.render();
    }
    return app.close_window or sys.programShouldClose();
}
const App = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    dev: r4os.r4dev.Context,
    current: ?status.Snapshot = null,
    choice: policy.Choice = .software,
    readable: bool = false,
    width: i32 = 640,
    height: i32 = 460,
    focus: Button = .policy,
    pressed: ?Button = null,
    exiting: bool = false,
    close_window: bool = false,
    paint_failed: bool = false,
    message: []const u8 = "Changes take effect after a restart.",

    fn loadPolicy(self: *App) void {
        var bytes: [policy.max_bytes]u8 = undefined;
        const saved = policy.read(&self.sys, &bytes) catch { self.readable = false; self.message = "Boot settings could not be read. Saving is disabled."; return; };
        self.choice = policy.selected(saved); self.readable = true;
    }
    fn poll(self: *App) bool {
        const before = self.current; self.current = status.Snapshot.read(&self.dev);
        return !std.meta.eql(before, self.current);
    }
    fn metrics(self: *App) void {
        var info: a.GuiWindowInfo = .{};
        if (self.desk.guiWindowInfo(&info) >= 0) { self.width = @max(480, info.client_w); self.height = @max(420, info.client_h); }
    }
    fn rect(self: *const App, button: Button) r4os.gui.Rect {
        return switch (button) {
            .policy => .{ .x = 12, .y = 248, .w = self.width - 24, .h = 28 },
            .save => .{ .x = 12, .y = self.height - 40, .w = 130, .h = 28 },
            .refresh => .{ .x = 154, .y = self.height - 40, .w = 90, .h = 28 },
            .back => .{ .x = self.width - 90, .y = self.height - 40, .w = 78, .h = 28 },
        };
    }
    fn enabled(self: *const App, b: Button) bool { return self.readable or b == .refresh or b == .back; }
    fn hit(self: *const App, x: i32, y: i32) ?Button {
        for (std.enums.values(Button)) |b| if (self.enabled(b) and self.rect(b).contains(x, y)) return b;
        return null;
    }
    fn key(self: *App, code: u8) void {
        const keys = r4os.gui.Key;
        if (code == keys.escape) { self.exiting = true; return; }
        if (code == keys.tab or code == keys.shift_tab) {
            for (0..4) |_| {
                self.focus = @enumFromInt((@as(u32, @intFromEnum(self.focus)) + (if (code == keys.tab) @as(u32, 1) else 3)) % 4);
                if (self.enabled(self.focus)) break;
            }
        } else if (code == keys.enter or code == ' ') self.activate(self.focus);
    }
    fn activate(self: *App, b: Button) void {
        if (!self.enabled(b)) return;
        switch (b) {
            .back => self.exiting = true,
            .refresh => self.loadPolicy(),
            .policy => self.choice = if (self.choice == .automatic) .software else .automatic,
            .save => {
                policy.save(&self.sys, self.choice) catch { self.message = "Save not confirmed. Refresh before retrying."; return; };
                self.message = "Saved for the next boot. Restart when ready.";
            },
        }
    }
    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.draw, self.width, self.height)) { .paint => |p| p, .failure => { self.paint_failed = true; return; } };
        defer paint.discard();
        var commands: [96]a.GuiFrameCommand = undefined; var resources: [8192]u8 = undefined;
        var builder: r4os.FrameCanvas = undefined;
        const canvas = paint.bufferedCanvas(&builder, &commands, &resources);
        var scratch: [512]u8 = undefined; var text: [224]u8 = undefined;
        _ = canvas.clear(face);
        _ = canvas.textClipped(12, 14, self.width - 24, &scratch, "Graphics driver and startup", 0, face);
        if (self.current) |current| {
            for (0..8) |i| _ = canvas.textClipped(12, 44 + @as(i32, @intCast(i)) * 24, self.width - 24, &scratch, current.line(&text, i), 0, face);
        } else _ = canvas.textClipped(12, 44, self.width - 24, &scratch, "Graphics state unavailable. Refresh after the transition.", 0, face);
        _ = canvas.textClipped(12, 292, self.width - 24, &scratch, "Firmware bundle version does not confirm GPU execution.", 0x404040, face);
        _ = canvas.textClipped(12, 316, self.width - 24, &scratch, "For one boot: select Software Graphics in the boot menu.", 0x404040, face);
        _ = canvas.textClipped(12, self.height - 68, self.width - 24, &scratch, self.message, 0, face);
        for (std.enums.values(Button)) |b| {
            const label = switch (b) { .policy => if (self.choice == .automatic) "Next boot: Automatic" else "Next boot: Software",
                .save => "Save startup", .refresh => "Refresh", .back => "Back" };
            _ = canvas.button(.{ .rect = self.rect(b), .text = label, .focused = b == self.focus, .is_cancel = b == .back,
                .state = if (!self.enabled(b)) .disabled else if (self.pressed == b) .pressed else .normal }, &scratch);
        }
        self.paint_failed = paint.present() < 0;
    }
};
