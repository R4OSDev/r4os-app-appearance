//! Saved brightness choices and independently confirmed driver status.
const std = @import("std");
const r4os = @import("r4os");
const r4std = @import("r4std");
const catalog = @import("r4gfx_desktop_outputs");
const settings = catalog.brightness_preferences;
const names = catalog.brightness_status;
const a = r4os.abi;
const face = r4os.gui.default_palette.face;
const Button = enum { decrease, increase, reset, save, close };
pub fn run(sys: r4os.r4sys.Context, desk: r4os.r4desk.Context, draw: r4os.r4draw.Context, key: catalog.topology.Key) bool {
    var app: App = .{ .sys = sys, .desk = desk, .draw = draw, .key = key };
    if (app.read()) |saved| { if (saved.find(key)) |choice| { app.level = choice.level; app.initialized = true; } }
        else |_| { app.message = "Could not read the brightness settings."; }
    _ = desk.guiSetTitle("Display brightness");
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
    level: u32 = 65535,
    initialized: bool = false,
    keys_available: bool = false,
    state: ?a.GfxOutputBrightness = null,
    width: i32 = 640,
    height: i32 = 420,
    focus: Button = .decrease,
    pressed: ?Button = null,
    exiting: bool = false,
    close_window: bool = false,
    message: []const u8 = "Choose a level, then save it for this display.",
    fn read(self: *App) !settings.Config {
        if (r4std.config.recoverDocumentSave(&self.sys, settings.path) < 0) return error.Save;
        var bytes: [settings.max_bytes]u8 = undefined;
        const count = self.sys.fileRead(settings.path, &bytes);
        if (count == -3) return .{};
        if (count <= 0 or count > bytes.len) return error.File;
        return settings.Config.parse(bytes[0..@intCast(count)]);
    }
    fn poll(self: *App) bool {
        const previous_keys = self.keys_available;
        var input: a.PlatformInputSnapshot = .{};
        self.keys_available = self.sys.platformInputSnapshot(&input) > 0 and input.version == 1 and
            input.size == @sizeOf(a.PlatformInputSnapshot) and input.capabilities & 1 != 0 and input.sources != 0;
        const previous = self.state;
        self.state = null;
        const snapshot = catalog.Snapshot.read(&self.draw) catch return previous != null or previous_keys != self.keys_available;
        for (snapshot.entries[0..snapshot.count]) |entry| {
            if (!std.meta.eql(entry.key, self.key) or !entry.active()) continue;
            var value: a.GfxOutputBrightness = .{};
            if (self.draw.gfxOutputBrightness(&entry.info.identity, &value) == a.gfx_output_ok and
                std.meta.eql(value.identity, entry.info.identity) and value.maximum <= 65535 and value.minimum <= value.maximum) {
                self.state = value;
                if (!self.initialized and value.flags & a.gfx_brightness_flag_current_known != 0) {
                    self.level = value.current; self.initialized = true;
                }
                if (self.usable()) self.level = std.math.clamp(self.level, value.minimum, value.maximum);
            }
            break;
        }
        return !std.meta.eql(previous, self.state) or previous_keys != self.keys_available;
    }
    fn usable(self: *const App) bool {
        const state = self.state orelse return false;
        return state.path != 0 and state.minimum < state.maximum and state.phase != a.gfx_brightness_phase_unavailable;
    }
    fn enabled(self: *const App, button: Button) bool {
        return button == .close or (self.usable() and (button != .reset or self.state.?.flags & a.gfx_brightness_flag_current_known != 0));
    }
    fn metrics(self: *App) void {
        var info: a.GuiWindowInfo = .{};
        if (self.desk.guiWindowInfo(&info) >= 0) { self.width = @max(480, info.client_w); self.height = @max(420, info.client_h); }
    }
    fn rect(self: *const App, button: Button) r4os.gui.Rect {
        return switch (button) {
            .decrease => .{ .x = 12, .y = 210, .w = 112, .h = 28 },
            .increase => .{ .x = 136, .y = 210, .w = 112, .h = 28 },
            .reset => .{ .x = 260, .y = 210, .w = 160, .h = 28 },
            .save => .{ .x = 12, .y = self.height - 40, .w = 140, .h = 28 },
            .close => .{ .x = self.width - 90, .y = self.height - 40, .w = 78, .h = 28 },
        };
    }
    fn hit(self: *const App, x: i32, y: i32) ?Button {
        for (std.enums.values(Button)) |button| if (self.enabled(button) and self.rect(button).contains(x, y)) return button;
        return null;
    }
    fn keypress(self: *App, key: u8) void {
        const keys = r4os.gui.Key;
        if (key == keys.escape) { self.exiting = true; return; }
        if (key == keys.tab or key == keys.shift_tab) {
            for (0..5) |_| {
                self.focus = @enumFromInt((@intFromEnum(self.focus) + @as(u32, if (key == keys.tab) 1 else 4)) % 5);
                if (self.enabled(self.focus)) break;
            }
        } else if (key == keys.enter or key == ' ') self.activate(self.focus)
        else if (key == keys.left) self.activate(.decrease)
        else if (key == keys.right) self.activate(.increase);
    }
    fn activate(self: *App, button: Button) void {
        if (!self.enabled(button)) return;
        switch (button) {
            .decrease => self.level = @max(self.state.?.minimum, self.level -| 3277),
            .increase => self.level = @min(self.state.?.maximum, self.level +| 3277),
            .reset => self.level = self.state.?.current,
            .save => self.save(),
            .close => self.exiting = true,
        }
        self.initialized = true;
    }
    fn save(self: *App) void {
        const saved = self.read() catch { self.message = "Could not read the current brightness settings."; return; };
        const next = saved.change(self.key, self.level) catch { self.message = "Could not update this display's brightness settings."; return; };
        var bytes: [settings.max_bytes]u8 = undefined;
        const encoded = next.encode(&bytes) catch { self.message = "Could not encode the brightness settings."; return; };
        if (r4std.config.saveDocument(&self.sys, settings.path, encoded) < 0) { self.message = "Could not save the brightness settings."; return; }
        if (self.desk.guiSetText("R4OS_APPEARANCE_RELOAD=1") < 0) { self.message = "Saved. Restart the Desktop to apply the setting."; return; }
        self.message = "Saved. The confirmed level updates after the change.";
    }
    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.draw, self.width, self.height)) { .paint => |value| value, .failure => return };
        defer paint.discard();
        var commands: [64]a.GuiFrameCommand = undefined; var resources: [4096]u8 = undefined;
        var builder: r4os.FrameCanvas = undefined;
        const canvas = paint.bufferedCanvas(&builder, &commands, &resources);
        var scratch: [256]u8 = undefined; var text: [180]u8 = undefined;
        _ = canvas.rect(.{ .x = 0, .y = 0, .w = self.width, .h = self.height }, face);
        _ = canvas.textClipped(12, 14, self.width - 24, &scratch, "Brightness for this display", 0, face);
        const selected = std.fmt.bufPrint(&text, "Selected level: {d}%", .{(self.level * 100 + 32767) / 65535}) catch "";
        _ = canvas.textClipped(12, 48, self.width - 24, &scratch, selected, 0, face);
        if (self.state) |state| {
            const observed = if (state.flags & a.gfx_brightness_flag_current_known != 0)
                std.fmt.bufPrint(&text, "Confirmed level: {d}%", .{(state.current * 100 + 32767) / 65535}) catch ""
                else "Confirmed level: unavailable";
            _ = canvas.textClipped(12, 80, self.width - 24, &scratch, observed, 0, face);
            _ = canvas.textClipped(12, 112, self.width - 24, &scratch, names.reason(state.reason), 0, face);
        } else _ = canvas.textClipped(12, 80, self.width - 24, &scratch, "Brightness control is unavailable for this display.", 0, face);
        _ = canvas.textClipped(12, 268, self.width - 24, &scratch, if (self.keys_available)
            "Brightness keys control the internal display." else "No supported brightness key source is connected.", 0x404040, face);
        _ = canvas.textClipped(12, self.height - 82, self.width - 24, &scratch, self.message, 0, face);
        for (std.enums.values(Button)) |button| {
            const label = switch (button) { .decrease => "Darker", .increase => "Brighter", .reset => "Use current level", .save => "Save brightness", .close => "Back" };
            _ = canvas.button(.{ .rect = self.rect(button), .text = label, .focused = self.focus == button,
                .state = if (!self.enabled(button)) .disabled else if (self.pressed == button) .pressed else .normal, .is_cancel = button == .close }, &scratch);
        }
        _ = paint.present();
    }
};
