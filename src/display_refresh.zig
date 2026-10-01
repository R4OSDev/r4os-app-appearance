//! Per-monitor VRR settings. The Desktop is the sole presenter/lease owner;
//! this page saves user choices and reads independently confirmed state.
const std = @import("std");
const r4os = @import("r4os");
const r4std = @import("r4std");
const catalog = @import("r4gfx_desktop_outputs");
const settings = catalog.refresh_preferences;
const names = catalog.refresh_status;
const a = r4os.abi;
const face = r4os.gui.default_palette.face;
const Button = enum { policy, flicker, retry, save, close };
pub fn run(sys: r4os.r4sys.Context, desk: r4os.r4desk.Context, draw: r4os.r4draw.Context, key: catalog.topology.Key) bool {
    var app: App = .{ .sys = sys, .desk = desk, .draw = draw, .key = key };
    if (app.read()) |saved| { if (saved.find(key)) |choice| app.policy = choice.policy; }
        else |_| { app.message = "Could not read the refresh settings."; }
    _ = desk.guiSetTitle("Variable refresh rate");
    _ = desk.guiSetMinSize(480, 420);
    app.metrics(); _ = app.poll(); app.render();
    var events = r4os.EventLoop.init(sys, desk, &.{});
    while (!app.exiting and !sys.programShouldClose()) {
        var redraw = true;
        switch (events.wait(r4os.time_contract.timeoutFinite(.{ .nanoseconds = 500 * std.time.ns_per_ms }))) {
            .message => |message| if (message.guiEvent()) |event| switch (@as(a.GuiEventKind, @enumFromInt(event.kind))) {
                .close => { app.exiting = true; app.close_window = true; },
                .resize => app.metrics(),
                .key_down => app.keypress(@intCast(event.key & 255)),
                .mouse_down => { app.pressed = app.hit(event.x, event.y); if (app.pressed) |button| app.focus = button; },
                .mouse_up => { const button = app.hit(event.x, event.y); if (button != null and button == app.pressed) app.activate(button.?); app.pressed = null; },
                else => {},
            },
            .timed_out => redraw = false,
            .failure => return true,
        }
        redraw = app.poll() or redraw;
        if (!app.exiting and redraw) app.render();
    }
    return app.close_window or sys.programShouldClose();
}
const App = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    key: catalog.topology.Key,
    policy: u32 = 1,
    state: ?a.GfxOutputRefresh = null,
    width: i32 = 640,
    height: i32 = 420,
    focus: Button = .policy,
    pressed: ?Button = null,
    exiting: bool = false,
    close_window: bool = false,
    message: []const u8 = "VRR follows animation. Idle content uses fixed refresh.",
    fn read(self: *App) !settings.Config {
        if (r4std.config.recoverDocumentSave(&self.sys, settings.path) < 0) return error.Save;
        var bytes: [settings.max_bytes]u8 = undefined;
        const count = self.sys.fileRead(settings.path, &bytes);
        if (count == -3) return .{};
        if (count <= 0 or count > bytes.len) return error.File;
        return settings.Config.parse(bytes[0..@intCast(count)]);
    }
    fn poll(self: *App) bool {
        const previous = self.state;
        self.state = null;
        const snapshot = catalog.Snapshot.read(&self.draw) catch return previous != null;
        for (snapshot.entries[0..snapshot.count]) |entry| {
            if (!std.meta.eql(entry.key, self.key) or !entry.active()) continue;
            var value: a.GfxOutputRefresh = .{};
            if (self.draw.gfxOutputRefresh(&entry.target, &value) == a.gfx_output_ok and std.meta.eql(value.target, entry.target)) self.state = value;
            break;
        }
        return !std.meta.eql(previous, self.state);
    }
    fn metrics(self: *App) void {
        var info: a.GuiWindowInfo = .{};
        if (self.desk.guiWindowInfo(&info) >= 0) { self.width = @max(480, info.client_w); self.height = @max(420, info.client_h); }
    }
    fn rect(self: *const App, button: Button) r4os.gui.Rect {
        return switch (button) {
            .policy => .{ .x = 12, .y = 208, .w = self.width - 24, .h = 28 },
            .flicker => .{ .x = 12, .y = 248, .w = @divTrunc(self.width - 36, 2), .h = 28 },
            .retry => .{ .x = @divTrunc(self.width, 2) + 6, .y = 248, .w = @divTrunc(self.width - 36, 2), .h = 28 },
            .save => .{ .x = 12, .y = self.height - 40, .w = 130, .h = 28 },
            .close => .{ .x = self.width - 90, .y = self.height - 40, .w = 78, .h = 28 },
        };
    }
    fn hit(self: *const App, x: i32, y: i32) ?Button {
        for (std.enums.values(Button)) |button| if (self.rect(button).contains(x, y)) return button;
        return null;
    }
    fn keypress(self: *App, key: u8) void {
        const keys = r4os.gui.Key;
        if (key == keys.escape) { self.exiting = true; return; }
        if (key == keys.tab or key == keys.shift_tab) {
            self.focus = @enumFromInt((@intFromEnum(self.focus) + @as(u32, if (key == keys.tab) 1 else 4)) % 5);
        } else if (key == keys.enter or key == ' ') self.activate(self.focus);
    }
    fn activate(self: *App, button: Button) void {
        switch (button) {
            .policy => self.policy = (self.policy + 1) % 3,
            .flicker => { self.policy = 0; self.save(true); },
            .retry => { if (self.policy == 0) self.policy = 1; self.save(false); },
            .save => self.save(null),
            .close => self.exiting = true,
        }
    }
    fn save(self: *App, blocked: ?bool) void {
        const saved = self.read() catch { self.message = "Could not read the current refresh settings."; return; };
        const next = changePreferences(&saved, self.key, self.policy, blocked) catch { self.message = "Could not update this monitor's refresh settings."; return; };
        var bytes: [settings.max_bytes]u8 = undefined;
        const encoded = next.encode(&bytes) catch { self.message = "Could not encode the refresh settings."; return; };
        if (r4std.config.saveDocument(&self.sys, settings.path, encoded) < 0) { self.message = "Could not save the refresh settings."; return; }
        const choice = next.find(self.key).?;
        self.policy = choice.policy;
        if (self.desk.guiSetText("R4OS_APPEARANCE_RELOAD=1") < 0) { self.message = "Saved. Restart the Desktop to apply the policy."; return; }
        self.message = if (choice.blocked) "VRR stays off. Use Retry VRR to clear the flicker lock." else "Saved. The Desktop applies the policy when eligible.";
    }
    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.draw, self.width, self.height)) { .paint => |value| value, .failure => return };
        defer paint.discard();
        var commands: [96]a.GuiFrameCommand = undefined; var resources: [8192]u8 = undefined;
        var builder: r4os.FrameCanvas = undefined;
        const canvas = paint.bufferedCanvas(&builder, &commands, &resources);
        var scratch: [256]u8 = undefined; var text: [180]u8 = undefined;
        _ = canvas.rect(.{ .x = 0, .y = 0, .w = self.width, .h = self.height }, face);
        _ = canvas.textClipped(12, 14, self.width - 24, &scratch, "Variable refresh rate for this monitor", 0, face);
        if (self.state) |state| {
            const cap = state.capabilities;
            const capable = cap.flags & a.gfx_refresh_cap_capable != 0;
            const ability = if (capable) std.fmt.bufPrint(&text, "Supported range: {d}.{d:0>3} - {d}.{d:0>3} Hz",
                .{cap.min_millihz/1000,cap.min_millihz%1000,cap.max_millihz/1000,cap.max_millihz%1000}) catch "" else "VRR is unavailable for this mode or output.";
            _ = canvas.textClipped(12, 44, self.width - 24, &scratch, ability, 0, face);
            _ = canvas.textClipped(12, 70, self.width - 24, &scratch, names.phase(state.status.phase), 0, face);
            _ = canvas.textClipped(12, 94, self.width - 24, &scratch, names.reason(state.status.reason), 0x404040, face);
            const measured = state.measured;
            const observed = if (measured.samples != 0) std.fmt.bufPrint(&text, "Measured mean: {d}.{d:0>3} Hz ({d} intervals)",
                .{measured.millihz/1000,measured.millihz%1000,measured.samples}) catch "" else "Measured refresh: waiting for hardware observations";
            _ = canvas.textClipped(12, 126, self.width - 24, &scratch, observed, 0, face);
            const nominal = std.fmt.bufPrint(&text, "Nominal mode: {d}.{d:0>3} Hz", .{cap.nominal_millihz/1000,cap.nominal_millihz%1000}) catch "";
            _ = canvas.textClipped(12, 152, self.width - 24, &scratch, nominal, 0x404040, face);
        } else _ = canvas.textClipped(12, 44, self.width - 24, &scratch, "VRR state unavailable. Ordinary presentation remains available.", 0, face);
        _ = canvas.textClipped(12, self.height - 82, self.width - 24, &scratch, self.message, 0, face);
        for (std.enums.values(Button)) |button| {
            const label = switch (button) { .policy => names.policy(self.policy), .flicker => "Flicker: disable VRR", .retry => "Retry VRR",
                .save => "Save policy", .close => "Back" };
            _ = canvas.button(.{ .rect = self.rect(button), .text = label, .focused = self.focus == button,
                .state = if (self.pressed == button) .pressed else .normal, .is_cancel = button == .close }, &scratch);
        }
        _ = paint.present();
    }
};

// A normal save preserves the latest on-disk lock, including when this
// window was opened before another settings window reported flicker.
// Only the explicit Retry button passes false; Flicker passes true.
fn changePreferences(saved: *const settings.Config, key: catalog.topology.Key, policy: u32, action: ?bool) !settings.Config {
    const blocked = action orelse if (saved.find(key)) |choice| choice.blocked else false;
    return saved.change(key, if (blocked) 0 else policy, blocked);
}

pub fn exercise() !void {
    const t = std.testing;
    const key: catalog.topology.Key = .{ .adapter = 17, .connector = 3, .receiver = @splat(1) };
    var other = key; other.connector = 4;
    var config: settings.Config = .{};
    config = try changePreferences(&config, other, 2, null);
    const untouched = config.find(other).?;
    config = try changePreferences(&config, key, 1, null);
    config = try changePreferences(&config, key, 1, true);
    var bytes: [settings.max_bytes]u8 = undefined;
    config = try settings.Config.parse(try config.encode(&bytes));
    // Save after reopening, and a stale window's nonzero selection, must
    // both preserve the durable fault. Shared client checks cover the
    // resulting Flicker/fixed ACK and subsequent explicit ClearFault ACK.
    for ([_]u32{ 0, 1, 2 }) |policy| {
        const serial = config.find(key).?.serial;
        config = try changePreferences(&config, key, policy, null);
        const choice = config.find(key).?;
        try t.expect(choice.blocked and choice.policy == 0 and choice.serial == serial + 1);
        config = try settings.Config.parse(try config.encode(&bytes));
    }
    config = try changePreferences(&config, key, 1, false);
    try t.expect(!config.find(key).?.blocked and config.find(key).?.policy == 1);
    config = try changePreferences(&config, key, 2, null);
    try t.expect(!config.find(key).?.blocked and config.find(key).?.policy == 2);
    try t.expectEqualDeep(untouched, config.find(other).?);
}
