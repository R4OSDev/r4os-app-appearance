//! Monitor color preferences and bounded ICC validation, using the shared CMM.
const std = @import("std");
const r4os = @import("r4os");
const r4std = @import("r4std");
const gfx = @import("r4gfx");
const catalog = @import("r4gfx_desktop_outputs");
const settings = catalog.color_preferences;
const a = r4os.abi;
const face = r4os.gui.default_palette.face;
const Button = enum { filename, intent, black_point, calibration, encoding, range, white, peak, test_output, keep, revert, standard, save, close };
const intents = [_][]const u8{ "Perceptual", "Relative colorimetric", "Saturation", "Absolute colorimetric" };
pub fn run(sys: r4os.r4sys.Context, desk: r4os.r4desk.Context, draw: r4os.r4draw.Context, raw: *const a.R4XStartContext, key: catalog.topology.Key, client: *catalog.control.Client) bool {
    if (!key.persistable()) return false;
    const colors = gfx.ColorV1Client.init(raw) catch return false;
    var app: App = .{ .sys = sys, .desk = desk, .draw = draw, .colors = colors, .key = key, .client = client };
    defer client.close(&sys);
    app.load(); app.metrics();
    _ = desk.guiSetTitle("Display color settings");
    _ = desk.guiSetMinSize(480, 560);
    app.metrics();
    app.render();
    var events = r4os.EventLoop.init(sys, desk, &.{});
    while (!app.exiting and !sys.programShouldClose()) {
        var redraw = true;
        const delay: u64 = if (app.waiting()) 100 else 500;
        switch (events.wait(r4os.time_contract.timeoutFinite(.{ .nanoseconds = delay * std.time.ns_per_ms }))) {
            .message => |message| if (message.guiEvent()) |event| switch (@as(a.GuiEventKind, @enumFromInt(event.kind))) {
                .close => { app.exiting = true; app.close_window = true; },
                .resize => app.metrics(),
                .key_down => app.keypress(event.key),
                .mouse_down => { app.pressed = app.hit(event.x, event.y); if (app.pressed) |button| app.focus = button; },
                .mouse_up => { const button = app.hit(event.x, event.y); if (button != null and button == app.pressed) app.activate(button.?); app.pressed = null; },
                else => {},
            },
            .failure => return true,
            .timed_out => redraw = false,
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
    colors: gfx.ColorV1Client,
    key: catalog.topology.Key,
    client: *catalog.control.Client,
    signal: a.GfxColorSignal = settings.sdr,
    displayed_second: u64 = 0,
    filename: r4os.gui.TextField(r4os.path.file_path_max + 1) = .{},
    intent: u32 = 1,
    flags: u32 = 1,
    width: i32 = 640,
    height: i32 = 560,
    focus: Button = .filename,
    pressed: ?Button = null,
    exiting: bool = false,
    close_window: bool = false,
    status: []const u8 = "Save a display profile or test the output color settings.",
    fn read(self: *App) !settings.Config {
        if (r4std.config.recoverDocumentSave(&self.sys, settings.path) < 0) return error.Save;
        var bytes: [settings.max_bytes]u8 = undefined;
        const count = self.sys.fileRead(settings.path, &bytes);
        if (count == -3) return .{};
        if (count <= 0 or count > bytes.len) return error.File;
        return settings.Config.parse(bytes[0..@intCast(count)]);
    }
    fn load(self: *App) void {
        const saved = self.read() catch { self.status = "Could not read the color settings."; return; };
        const choice = saved.find(self.key) orelse settings.Choice{ .key = self.key };
        self.filename.set(std.mem.span(choice.profilePath()));
        self.intent = choice.intent; self.flags = choice.flags; self.signal = choice.signal;
    }
    fn metrics(self: *App) void {
        var info: a.GuiWindowInfo = .{};
        if (self.desk.guiWindowInfo(&info) >= 0) { self.width = @max(480, info.client_w); self.height = @max(560, info.client_h); }
    }
    fn rect(self: *const App, button: Button) r4os.gui.Rect {
        return switch (button) {
            .filename => .{ .x = 12, .y = 70, .w = self.width - 24, .h = 26 },
            .intent => .{ .x = 12, .y = 116, .w = self.width - 24, .h = 28 },
            .black_point => .{ .x = 12, .y = 158, .w = self.width - 24, .h = 28 },
            .calibration => .{ .x = 12, .y = 200, .w = self.width - 24, .h = 28 },
            .encoding => .{ .x = 12, .y = 244, .w = self.width - 24, .h = 28 },
            .range => .{ .x = 12, .y = 286, .w = @divTrunc(self.width - 36, 2), .h = 28 },
            .white => .{ .x = @divTrunc(self.width, 2) + 6, .y = 286, .w = @divTrunc(self.width - 36, 2), .h = 28 },
            .peak => .{ .x = 12, .y = 328, .w = @divTrunc(self.width - 36, 2), .h = 28 },
            .test_output => .{ .x = @divTrunc(self.width, 2) + 6, .y = 328, .w = @divTrunc(self.width - 36, 2), .h = 28 },
            .keep => .{ .x = 12, .y = 370, .w = 142, .h = 28 },
            .revert => .{ .x = 164, .y = 370, .w = 142, .h = 28 },
            .standard => .{ .x = 12, .y = self.height - 40, .w = 142, .h = 28 },
            .save => .{ .x = 164, .y = self.height - 40, .w = 120, .h = 28 },
            .close => .{ .x = self.width - 90, .y = self.height - 40, .w = 78, .h = 28 },
        };
    }
    fn hit(self: *const App, x: i32, y: i32) ?Button {
        for (std.enums.values(Button)) |button| if (self.enabled(button) and self.rect(button).contains(x, y)) return button;
        return null;
    }
    fn keypress(self: *App, key: u32) void {
        const keys = r4os.gui.Key;
        if (key == keys.escape) { self.exiting = true; return; }
        if (key == keys.tab or key == keys.shift_tab) {
            const count = std.enums.values(Button).len;
            const index: usize = @intFromEnum(self.focus);
            self.focus = @enumFromInt(if (key == keys.tab) (index + 1) % count else (index + count - 1) % count);
        } else if (self.focus == .filename and !self.waiting()) {
            if (key == keys.enter) self.activate(.save)
            else if (key == keys.ctrl_c or key == keys.ctrl_v or key == keys.ctrl_x) _ = self.filename.handleClipboardKey(&self.desk, @intCast(key))
            else _ = self.filename.handleCodepoint(key);
        } else if (key == keys.enter or key == ' ') self.activate(self.focus);
    }
    fn activate(self: *App, button: Button) void {
        if (!self.enabled(button)) return;
        switch (button) {
            .filename => {},
            .intent => self.intent = @intCast((self.intent + 1) % intents.len),
            .black_point => self.flags ^= 1,
            .calibration => self.flags ^= 2,
            .encoding => self.nextEncoding(),
            .range => self.signal.range = if (self.signal.range == 1) 2 else 1,
            .white => self.signal.reference_white = nextLuminance(self.signal.reference_white, &.{ 100, 150, 203, 250, 300, 400 }),
            .peak => self.signal.peak = nextLuminance(self.signal.peak, &.{ 500, 1000, 2000, 4000, 10000 }),
            .test_output => self.testOutput(),
            .keep => { _ = self.client.request(&self.sys, 2, null); },
            .revert => { _ = self.client.request(&self.sys, 3, null); },
            .standard => { self.filename.clear(); self.intent = 1; self.flags = 1; self.save(); },
            .save => self.save(),
            .close => self.exiting = true,
        }
    }
    fn waiting(self: *const App) bool { return self.client.pending != null or catalog.control.active(self.client.state.phase); }
    fn enabled(self: *const App, button: Button) bool {
        return switch (button) {
            .close => true,
            .keep => self.client.pending == null and self.client.state.phase == 2 and std.meta.eql(self.client.state.owner, self.client.owner),
            .revert => self.client.pending == null and catalog.control.active(self.client.state.phase) and std.meta.eql(self.client.state.owner, self.client.owner),
            .white, .peak => !self.waiting() and self.signal.transfer != 1,
            else => !self.waiting(),
        };
    }
    fn nextEncoding(self: *App) void {
        const previous = self.signal;
        self.signal = settings.sdr;
        if (previous.transfer == 1 and previous.bpc == 8) {
            self.signal.bpc = 10; self.signal.format = a.gfx_buffer_format_xrgb2101010;
        } else if (previous.transfer != 4) {
            self.signal.bpc = 10; self.signal.format = a.gfx_buffer_format_xrgb2101010;
            self.signal.primaries = 3; self.signal.transfer = if (previous.transfer == 3) 4 else 3;
            self.signal.range = 2; self.signal.reference_white = 2_030_000; self.signal.peak = 10_000_000;
            // The compositor has no content mastering/CLL measurement. CTA
            // unknown values stay zero; monitor limits are not mastering data.
            self.signal.metadata_valid = 1;
        }
    }
    fn nextLuminance(current: u32, values: []const u32) u32 {
        for (values) |value| if (value * 10000 > current) return value * 10000;
        return values[0] * 10000;
    }
    fn testOutput(self: *App) void {
        const snapshot = catalog.Snapshot.read(&self.draw) catch { self.status = "Display information changed. Try again."; return; };
        const entry = for (snapshot.entries[0..snapshot.count]) |value| { if (std.meta.eql(value.key, self.key)) break value; }
            else { self.status = "This monitor is no longer connected."; return; };
        const saved = self.read() catch { self.status = "Could not read the color settings."; return; };
        if (!catalog.color.profileEncoding(self.signal)) if (saved.find(self.key)) |choice| if (choice.enabled()) {
            self.status = "Reset and save the ICC profile before testing this output encoding."; return;
        };
        if (!self.client.poll(&self.sys) or !self.client.requestColor(&self.sys, .{ .output = entry.info.identity, .signal = self.signal })) {
            self.status = "The Desktop could not start the color change."; return;
        }
        self.status = "Testing output color settings...";
    }
    fn poll(self: *App) bool {
        const before = self.client.state;
        const previous_error = self.client.last_error;
        _ = if (self.client.pending != null) self.client.retry(&self.sys) else self.client.poll(&self.sys);
        const state = self.client.state;
        if (state.phase != before.phase or state.result != before.result) {
            if (state.phase == 2) { self.focus = .revert; self.pressed = null; }
            if (state.phase == 4 and state.result == 0) { self.load(); self.status = "Output color settings kept."; }
            if (state.phase == 4 and state.result != 0) self.status = "Color settings applied, but saving failed.";
            if (state.phase == 5) { self.load(); self.status = "Previous output color settings restored."; }
            if (state.phase == 6) self.status = "Color change failed or is unsupported. Check the display and profile settings.";
        }
        const second = (self.sys.monotonicNanoseconds() orelse 0) / std.time.ns_per_s;
        const changed = !std.meta.eql(before, state) or previous_error != self.client.last_error or (state.phase == 2 and second != self.displayed_second);
        self.displayed_second = second; return changed;
    }
    fn save(self: *App) void {
        var choice: settings.Choice = .{ .key = self.key, .intent = self.intent, .flags = self.flags };
        choice.setPath(self.filename.value()) catch { self.status = "Enter an absolute file path, or leave it empty."; return; };
        // Re-read before saving to preserve choices for other/absent monitors.
        const saved = self.read() catch { self.status = "Could not read the current color settings."; return; };
        if (saved.find(self.key)) |previous| choice.signal = previous.signal;
        const next = saved.remember(choice) catch { self.status = "The monitor cannot be saved in the color settings."; return; };
        const snapshot = catalog.Snapshot.read(&self.draw) catch { self.status = "Display information changed. Try again."; return; };
        const entry = for (snapshot.entries[0..snapshot.count]) |value| { if (std.meta.eql(value.key, self.key)) break value; }
            else { self.status = "This monitor is no longer connected."; return; };
        if (choice.enabled()) {
            const state = entry.color orelse { self.status = "Color profiles are unavailable for this display driver."; return; };
            if (state.flags & 7 != 7 or !catalog.color.profileEncoding(state)) {
                self.status = "This output encoding does not support display profiles yet."; return;
            }
            var profile = catalog.profiles.Owner(gfx).openFile(self.sys.allocator(), self.colors, &self.sys, choice.profilePath(), choice.intent, choice.flags)
                catch { self.status = "Could not open a compatible ICC display profile."; return; };
            if (!profile.close()) { self.status = "The color profile could not be released."; return; }
        }
        var bytes: [settings.max_bytes]u8 = undefined;
        const encoded = next.encode(&bytes) catch { self.status = "The color settings could not be encoded."; return; };
        if (r4std.config.saveDocument(&self.sys, settings.path, encoded) < 0) { self.status = "Could not save the color settings."; return; }
        if (self.desk.guiSetText("R4OS_APPEARANCE_RELOAD=1") < 0) { self.status = "Saved. Restart the Desktop to apply the profile."; return; }
        self.status = if (choice.enabled()) "Display profile saved." else "Display profile disabled.";
    }
    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.draw, self.width, self.height)) { .paint => |value| value, .failure => return };
        defer paint.discard();
        var commands: [160]a.GuiFrameCommand = undefined; var resources: [12288]u8 = undefined;
        var builder: r4os.FrameCanvas = undefined;
        const canvas = paint.bufferedCanvas(&builder, &commands, &resources);
        var scratch: [1024]u8 = undefined; var text: [160]u8 = undefined;
        _ = canvas.clear(face);
        _ = canvas.textClipped(12, 16, self.width - 24, &scratch, "Color settings for the selected monitor", 0, face);
        _ = canvas.textClipped(12, 47, self.width - 24, &scratch, "ICC profile path:", 0, face);
        self.filename.focused = self.focus == .filename;
        _ = self.filename.draw(canvas, self.rect(.filename), &scratch);
        for (std.enums.values(Button)) |button| {
            if (button == .filename) continue;
            const label = switch (button) {
                .intent => std.fmt.bufPrint(&text, "Rendering intent: {s}", .{intents[self.intent]}) catch "",
                .black_point => if (self.flags & 1 != 0) "Black-point compensation: On" else "Black-point compensation: Off",
                .calibration => if (self.flags & 2 != 0) "Apply profile calibration: On" else "Apply profile calibration: Off",
                .encoding => switch (self.signal.transfer) { 3 => "Output: HDR10 / PQ, 10 bit", 4 => "Output: HDR / HLG, 10 bit",
                    else => if (self.signal.bpc == 10) "Output: SDR, 10 bit" else "Output: SDR, 8 bit" },
                .range => if (self.signal.range == 1) "RGB range: Full" else "RGB range: Limited",
                .white => std.fmt.bufPrint(&text, "SDR white: {d} cd/m2", .{self.signal.reference_white / 10000}) catch "",
                .peak => std.fmt.bufPrint(&text, "Peak: {d} cd/m2", .{self.signal.peak / 10000}) catch "",
                .test_output => "Test output", .keep => "Keep", .revert => "Revert",
                .standard => "Reset profile", .save => "Save profile", .close => "Back", .filename => unreachable,
            };
            _ = canvas.button(.{ .rect = self.rect(button), .text = label, .focused = self.focus == button,
                .state = if (!self.enabled(button)) .disabled else if (self.pressed == button) .pressed else .normal, .is_cancel = button == .close }, &scratch);
        }
        _ = canvas.textClipped(12, 412, self.width - 24, &scratch, "SDR gray steps in the current output:", 0, face);
        for (0..16) |i| {
            const level: u32 = @intCast(i * 17);
            const left = 12 + @divTrunc((self.width - 24) * @as(i32, @intCast(i)), 16);
            const right = 12 + @divTrunc((self.width - 24) * @as(i32, @intCast(i + 1)), 16);
            _ = canvas.rect(.{ .x = left, .y = 435, .w = right - left, .h = 24 }, level * 0x010101);
        }
        const status = if (self.client.state.phase == 2) std.fmt.bufPrint(&text, "Keep this color output? Reverting in {d} seconds.",
            .{(self.client.state.deadline_ns -| (self.sys.monotonicNanoseconds() orelse 0) +| (std.time.ns_per_s - 1)) / std.time.ns_per_s}) catch "Keep this color output?"
            else self.status;
        _ = canvas.textClipped(12, self.height - 82, self.width - 24, &scratch, status, 0, face);
        _ = paint.present();
    }
};
