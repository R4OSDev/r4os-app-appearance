//! Existing Appearance display page, backed by the Desktop confirmation owner.
const std = @import("std");
const r4os = @import("r4os");
const catalog = @import("r4gfx_desktop_outputs");
const control = catalog.control;
const topology = catalog.topology;
const a = r4os.abi;
const Rect = r4os.gui.Rect;
const Button = enum { monitor, mode_previous, mode_next, scale_down, scale_up, rotate, primary, left, right, above, below, clone, enabled, colors, vrr, refresh, apply, keep, revert, close };
const all_buttons = std.enums.values(Button);
const scales = [_]u32{ 60, 90, 120, 150, 180, 210, 240, 300, 360, 480 };
const face = r4os.gui.default_palette.face;
pub fn run(sys: r4os.r4sys.Context, desk: r4os.r4desk.Context, draw: r4os.r4draw.Context, instance: u64, raw: *const a.R4XStartContext) ?i32 {
    var client = control.Client.init(&sys, instance) orelse return null;
    if (!client.poll(&sys) or client.state.flags & 1 == 0) return null;
    const layout = control.decode(&client.state.layout) catch return null;
    var app: App = .{ .sys = sys, .desk = desk, .draw = draw, .client = client, .edit = layout, .raw = raw };
    return app.run();
}
const App = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    client: control.Client,
    edit: topology.Layout,
    raw: ?*const a.R4XStartContext = null,
    snapshot: catalog.Snapshot = .{},
    modes: [a.gfx_output_max_modes]a.GfxOutputMode = @splat(.{}),
    mode_count: usize = 0,
    selected: usize = 0,
    width: i32 = 640,
    height: i32 = 460,
    dirty: bool = false,
    exiting: bool = false,
    focus: Button = .monitor,
    pressed: ?Button = null,
    status: []const u8 = "Arrange the displays, then test your changes.",
    dragging: ?struct { x: i32, y: i32, origin: topology.Point, numerator: i64, denominator: i64 } = null,
    displayed_second: u64 = 0,
    paint_failed: bool = false,

    fn run(self: *App) i32 {
        if (self.desk.programWindowId() < 0) return 0;
        _ = self.desk.guiSetTitle("Display settings");
        _ = self.desk.guiSetMinSize(480, 420);
        defer self.client.close(&self.sys);
        self.refreshCatalog(); self.metrics(); self.render();
        var events = r4os.EventLoop.init(self.sys, self.desk, &.{});
        while (!self.exiting and !self.sys.programShouldClose()) {
            const delay: u64 = if (self.waiting()) 100 else 500;
            var redraw = true;
            switch (events.wait(r4os.time_contract.timeoutFinite(.{ .nanoseconds = delay * std.time.ns_per_ms }))) {
                .message => |message| if (message.guiEvent()) |event| switch (@as(a.GuiEventKind, @enumFromInt(event.kind))) {
                    .close => self.exiting = true,
                    .resize => self.metrics(),
                    .key_down => self.key(@intCast(event.key & 0xff)),
                    .mouse_down => self.mouseDown(event.x, event.y),
                    .mouse_move => self.mouseMove(event.x, event.y),
                    .mouse_up => {
                        if (self.dragging != null) { self.snap(); self.dragging = null; }
                        const target = self.hit(event.x, event.y);
                        if (target != null and target == self.pressed) self.activate(target.?);
                        self.pressed = null;
                    },
                    else => {},
                },
                .timed_out => redraw = false,
                .failure => |rc| return rc,
            }
            const before = self.client.state;
            const previous_error = self.client.last_error;
            _ = if (self.client.pending != null) self.client.retry(&self.sys) else self.client.poll(&self.sys);
            if (!self.dirty and !std.meta.eql(before.layout, self.client.state.layout)) {
                self.edit = control.decode(&self.client.state.layout) catch self.edit;
                self.selected = @min(self.selected, self.edit.count - 1); self.refreshCatalog();
            }
            if (before.phase != 2 and self.client.state.phase == 2) { self.focus = .revert; self.pressed = null; }
            const second = if (self.client.state.phase == 2) (self.sys.monotonicNanoseconds() orelse 0) / std.time.ns_per_s else 0;
            redraw = redraw or !std.meta.eql(before, self.client.state) or previous_error != self.client.last_error or second != self.displayed_second;
            self.displayed_second = second;
            if (!self.exiting and (redraw or self.paint_failed)) self.render();
        }
        return 0;
    }
    fn metrics(self: *App) void {
        var info: a.GuiWindowInfo = .{};
        if (self.desk.guiWindowInfo(&info) >= 0) { self.width = @max(480, info.client_w); self.height = @max(420, info.client_h); }
    }
    fn waiting(self: *const App) bool { return self.client.pending != null or control.active(self.client.state.phase); }
    fn mine(self: *const App) bool { return std.meta.eql(self.client.owner, self.client.state.owner); }
    fn refreshCatalog(self: *App) void {
        self.mode_count = 0;
        self.snapshot = catalog.Snapshot.read(&self.draw) catch return;
        const key_value = self.edit.outputs[self.selected].key;
        const entry = for (self.snapshot.entries[0..self.snapshot.count]) |value| {
            if (std.meta.eql(value.key, key_value)) break value;
        } else return;
        if (entry.info.flags & a.gfx_output_flag_fixed_geometry != 0 or entry.info.limits.flags & a.gfx_output_limit_modeset == 0) return;
        if (entry.info.mode_count > self.modes.len) return;
        for (0..entry.info.mode_count) |i| {
            var mode: a.GfxOutputMode = .{};
            if (self.draw.outputs().mode(&entry.info.identity, @intCast(i), &mode) != a.gfx_output_ok) { self.mode_count = 0; return; }
            if (mode.width == 0 or mode.height == 0 or mode.pixel_clock_hz == 0 or
                mode.flags & (a.gfx_output_mode_geometry_only | a.gfx_output_mode_interlaced | a.gfx_output_mode_420_only) != 0) continue;
            self.modes[self.mode_count] = mode; self.mode_count += 1;
        }
    }
    fn enabled(self: *const App, button: Button) bool {
        const idle = !self.waiting();
        return switch (button) {
            .close => true,
            .monitor => idle and self.edit.count > 1,
            .keep => self.mine() and self.client.state.phase == 2 and self.client.pending == null,
            .revert => self.mine() and control.active(self.client.state.phase) and self.client.pending == null,
            .mode_previous, .mode_next => idle and self.mode_count > 1,
            .primary => idle and self.edit.outputs[self.selected].enabled,
            .left, .right, .above, .below, .clone => idle and self.edit.count > 1 and self.edit.outputs[self.selected].enabled,
            .enabled => idle and !self.edit.outputs[self.selected].primary,
            .apply => idle and self.dirty,
            .colors => idle and self.raw != null and self.edit.outputs[self.selected].key.persistable(),
            .vrr => idle and self.edit.outputs[self.selected].key.persistable(),
            else => idle,
        };
    }
    fn rect(self: *const App, button: Button) Rect {
        return switch (button) {
            .monitor => .{ .x = self.width - 142, .y = 10, .w = 130, .h = 26 },
            .mode_previous => .{ .x = self.width - 104, .y = 174, .w = 40, .h = 26 },
            .mode_next => .{ .x = self.width - 52, .y = 174, .w = 40, .h = 26 },
            .scale_down => .{ .x = 106, .y = 212, .w = 28, .h = 26 },
            .scale_up => .{ .x = 142, .y = 212, .w = 28, .h = 26 },
            .rotate => .{ .x = 186, .y = 212, .w = 130, .h = 26 },
            .primary => .{ .x = self.width - 148, .y = 212, .w = 136, .h = 26 },
            .left => .{ .x = 12, .y = 250, .w = 64, .h = 26 },
            .right => .{ .x = 84, .y = 250, .w = 64, .h = 26 },
            .above => .{ .x = 156, .y = 250, .w = 64, .h = 26 },
            .below => .{ .x = 228, .y = 250, .w = 64, .h = 26 },
            .clone => .{ .x = self.width - 148, .y = 250, .w = 136, .h = 26 },
            .enabled => .{ .x = 12, .y = 288, .w = 170, .h = 26 },
            .colors => .{ .x = self.width - 148, .y = 288, .w = 136, .h = 26 },
            .vrr => .{ .x = 190, .y = 288, .w = 134, .h = 26 },
            .refresh, .keep => .{ .x = 12, .y = self.height - 40, .w = 90, .h = 28 },
            .apply, .revert => .{ .x = 112, .y = self.height - 40, .w = 106, .h = 28 },
            .close => .{ .x = self.width - 90, .y = self.height - 40, .w = 78, .h = 28 },
        };
    }
    fn shown(self: *const App, button: Button) bool {
        return switch (button) { .refresh, .apply => !self.waiting(), .keep, .revert => self.waiting(), else => true };
    }
    fn hit(self: *const App, x: i32, y: i32) ?Button {
        for (all_buttons) |button| if (self.shown(button) and self.enabled(button) and self.rect(button).contains(x, y)) return button;
        return null;
    }
    fn key(self: *App, code: u8) void {
        const keys = r4os.gui.Key;
        if (code == keys.escape) { if (self.enabled(.revert)) self.activate(.revert) else self.exiting = true; return; }
        if (code == keys.tab or code == keys.shift_tab) {
            var index: usize = @intFromEnum(self.focus);
            for (0..all_buttons.len) |_| {
                index = if (code == keys.shift_tab) (index + all_buttons.len - 1) % all_buttons.len else (index + 1) % all_buttons.len;
                const target = all_buttons[index];
                if (self.shown(target) and self.enabled(target)) { self.focus = target; break; }
            }
        } else if (code == keys.enter or code == ' ') self.activate(self.focus);
    }
    fn activate(self: *App, button: Button) void {
        if (!self.enabled(button)) return;
        const value = &self.edit.outputs[self.selected];
        switch (button) {
            .monitor => { self.selected = (self.selected + 1) % self.edit.count; self.refreshCatalog(); return; },
            .mode_previous, .mode_next => {
                var selected: usize = 0;
                for (self.modes[0..self.mode_count], 0..) |mode, i| if (mode.width == value.view.pixel_w and mode.height == value.view.pixel_h and mode.refresh_millihz == value.refresh_millihz) { selected = i; break; };
                selected = if (button == .mode_previous) (selected + self.mode_count - 1) % self.mode_count else (selected + 1) % self.mode_count;
                const mode = self.modes[selected]; value.view.pixel_w = mode.width; value.view.pixel_h = mode.height; value.refresh_millihz = mode.refresh_millihz;
            },
            .scale_down, .scale_up => {
                var chosen: u32 = value.view.scale;
                if (button == .scale_up) {
                    for (scales) |scale| if (scale > value.view.scale) { chosen = scale; break; };
                } else {
                    for (scales) |scale| if (scale < value.view.scale) { chosen = scale; };
                }
                value.view.scale = chosen;
            },
            .rotate => value.view.rotation = @enumFromInt((@as(u32, @intFromEnum(value.view.rotation)) + 1) % 4),
            .primary => {
                for (self.edit.outputs[0..self.edit.count], 0..) |*output, i| output.primary = i == self.selected;
                self.edit.primary = self.selected;
            },
            .left, .right, .above, .below, .clone => if (!self.arrange(button)) return,
            .enabled => value.enabled = !value.enabled,
            .colors => {
                if (@import("display_color.zig").run(self.sys, self.desk, self.draw, self.raw.?, value.key, &self.client)) { self.exiting = true; return; }
                _ = self.desk.guiSetTitle("Display settings"); self.metrics(); self.refreshCatalog();
                return;
            },
            .vrr => {
                if (@import("display_refresh.zig").run(self.sys, self.desk, self.draw, value.key)) { self.exiting = true; return; }
                _ = self.desk.guiSetTitle("Display settings"); self.metrics(); self.refreshCatalog();
                return;
            },
            .refresh => {
                if (self.client.poll(&self.sys)) {
                    self.edit = control.decode(&self.client.state.layout) catch self.edit;
                    self.selected = @min(self.selected, self.edit.count - 1); self.dirty = false; self.refreshCatalog();
                    self.status = "Current display settings loaded.";
                }
                return;
            },
            .apply => {
                const encoded = control.encode(&self.edit);
                const layout = control.decode(&encoded) catch { self.status = "Separate overlapping displays, or use matching clone sizes."; return; };
                if (self.client.request(&self.sys, 1, &layout)) { self.dirty = false; self.status = "Testing display settings..."; }
                return;
            },
            .keep => { _ = self.client.request(&self.sys, 2, null); return; },
            .revert => { _ = self.client.request(&self.sys, 3, null); return; },
            .close => { self.exiting = true; return; },
        }
        self.dirty = true; self.status = "Changes are a preview. Test them before keeping them.";
    }
    fn anchor(self: *const App) ?usize {
        if (self.edit.primary != self.selected) return self.edit.primary;
        for (self.edit.outputs[0..self.edit.count], 0..) |value, i| if (i != self.selected and value.enabled) return i;
        return null;
    }
    fn arrange(self: *App, button: Button) bool {
        const anchor_index = self.anchor() orelse return false;
        const other = &self.edit.outputs[anchor_index];
        const value = &self.edit.outputs[self.selected];
        const bounds = other.view.logical() catch return false;
        const own = value.view.logical() catch return false;
        if (button == .clone) {
            if (bounds.w != own.w or bounds.h != own.h) { self.status = "Cloning needs matching desktop sizes. Adjust resolution or scale."; return false; }
            const group = if (other.clone_group != 0) other.clone_group else @as(u8, @intCast(anchor_index + 1));
            other.clone_group = group; value.clone_group = group; value.view.origin = other.view.origin; return true;
        }
        value.clone_group = 0;
        value.view.origin = other.view.origin;
        switch (button) {
            .left => value.view.origin.x -|= @intCast(own.w),
            .right => value.view.origin.x +|= @intCast(bounds.w),
            .above => value.view.origin.y -|= @intCast(own.h),
            .below => value.view.origin.y +|= @intCast(bounds.h),
            else => {},
        }
        return true;
    }
    const Diagram = struct { x: i64, y: i64, numerator: i64, denominator: i64, left: i32, top: i32 };
    fn diagram(self: *const App) Diagram {
        var x: i64 = std.math.maxInt(i32); var y = x;
        var right: i64 = std.math.minInt(i32); var bottom = right;
        for (self.edit.outputs[0..self.edit.count]) |output| {
            const rect_value = output.view.logical() catch continue;
            x = @min(x, rect_value.x); y = @min(y, rect_value.y);
            right = @max(right, rect_value.right()); bottom = @max(bottom, rect_value.bottom());
        }
        const w: i64 = @max(1, right - x); const h: i64 = @max(1, bottom - y);
        const available: i64 = self.width - 48;
        const numerator: i64 = if (available * h < 88 * w) available else 88;
        const denominator: i64 = if (available * h < 88 * w) w else h;
        return .{ .x = x, .y = y, .numerator = numerator, .denominator = denominator,
            .left = 24 + @as(i32, @intCast(@divTrunc(available - @divTrunc(w * numerator, denominator), 2))),
            .top = 48 + @as(i32, @intCast(@divTrunc(88 - @divTrunc(h * numerator, denominator), 2))) };
    }
    fn outputBox(self: *const App, index: usize) Rect {
        const diagram_value = self.diagram();
        const bounds = self.edit.outputs[index].view.logical() catch return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return .{ .x = diagram_value.left + @as(i32, @intCast(@divTrunc((@as(i64, bounds.x) - diagram_value.x) * diagram_value.numerator, diagram_value.denominator))),
            .y = diagram_value.top + @as(i32, @intCast(@divTrunc((@as(i64, bounds.y) - diagram_value.y) * diagram_value.numerator, diagram_value.denominator))),
            .w = @max(4, @as(i32, @intCast(@divTrunc(bounds.w * diagram_value.numerator, diagram_value.denominator)))),
            .h = @max(4, @as(i32, @intCast(@divTrunc(bounds.h * diagram_value.numerator, diagram_value.denominator)))) };
    }
    fn mouseDown(self: *App, x: i32, y: i32) void {
        self.pressed = self.hit(x, y);
        if (self.pressed) |button| { self.focus = button; return; }
        if (self.waiting()) return;
        for (0..self.edit.count) |i| if (self.outputBox(i).contains(x, y)) {
            self.selected = i; self.refreshCatalog();
            const preview = self.diagram();
            if (self.edit.outputs[i].enabled) self.dragging = .{ .x = x, .y = y, .origin = self.edit.outputs[i].view.origin,
                .numerator = preview.numerator, .denominator = preview.denominator };
            break;
        };
    }
    fn mouseMove(self: *App, x: i32, y: i32) void {
        const dragging = self.dragging orelse return;
        const value = &self.edit.outputs[self.selected];
        const dx = @divTrunc((@as(i64, x) - dragging.x) * dragging.denominator, dragging.numerator);
        const dy = @divTrunc((@as(i64, y) - dragging.y) * dragging.denominator, dragging.numerator);
        value.view.origin = .{ .x = @intCast(std.math.clamp(@as(i64, dragging.origin.x) + dx, -131072, 131072)),
            .y = @intCast(std.math.clamp(@as(i64, dragging.origin.y) + dy, -131072, 131072)) };
        value.clone_group = 0; self.dirty = true;
    }
    fn snap(self: *App) void {
        const value = &self.edit.outputs[self.selected];
        const own = value.view.logical() catch return;
        for (self.edit.outputs[0..self.edit.count], 0..) |other, i| {
            if (i == self.selected or !other.enabled) continue;
            const bounds = other.view.logical() catch continue;
            for ([_]i64{ bounds.x, bounds.right(), @as(i64, bounds.x) - own.w }) |x|
                if (@abs(@as(i64, value.view.origin.x) - x) <= 32) { value.view.origin.x = @intCast(x); break; };
            for ([_]i64{ bounds.y, bounds.bottom(), @as(i64, bounds.y) - own.h }) |y|
                if (@abs(@as(i64, value.view.origin.y) - y) <= 32) { value.view.origin.y = @intCast(y); break; };
        }
    }
    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.draw, self.width, self.height)) {
            .paint => |value| value, .failure => { self.paint_failed = true; return; },
        };
        defer paint.discard();
        var commands: [160]a.GuiFrameCommand = undefined;
        var resources: [12288]u8 = undefined;
        var builder: r4os.FrameCanvas = undefined;
        const canvas = paint.bufferedCanvas(&builder, &commands, &resources);
        var scratch: [512]u8 = undefined; var text: [192]u8 = undefined;
        _ = canvas.clear(face);
        _ = canvas.textClipped(12, 16, self.width - 170, &scratch, "Displays - drag to arrange", 0, face);
        _ = canvas.rect(.{ .x = 12, .y = 42, .w = self.width - 24, .h = 100 }, 0xffffff);
        for (self.edit.outputs[0..self.edit.count], 0..) |output, i| {
            const box = self.outputBox(i);
            const color: u32 = if (!output.enabled) 0x909090 else if (i == self.selected) 0x164c96 else 0x366b66;
            _ = canvas.rect(box, if (output.primary) 0 else 0x707070);
            _ = canvas.rect(box.inset(2, 2), color);
            const label = std.fmt.bufPrint(&text, "{d}{s}", .{ i + 1, if (output.primary) " *" else "" }) catch "";
            _ = canvas.textClipped(box.x + 5, box.y + 5, @max(0, box.w - 10), &scratch, label, 0xffffff, color);
        }
        const selected = self.edit.outputs[self.selected];
        var name: []const u8 = "Display";
        for (self.snapshot.entries[0..self.snapshot.count]) |*entry| if (std.meta.eql(entry.key, selected.key) and entry.name[0] != 0) { name = std.mem.sliceTo(&entry.name, 0); break; };
        const monitor = std.fmt.bufPrint(&text, "{s} {d}  ({d}, {d})", .{ name, self.selected + 1, selected.view.origin.x, selected.view.origin.y }) catch "";
        _ = canvas.textClipped(12, 151, self.width - 24, &scratch, monitor, 0, face);
        const mode = if (selected.refresh_millihz == 0)
            std.fmt.bufPrint(&text, "{d} x {d}, current refresh", .{ selected.view.pixel_w, selected.view.pixel_h }) catch ""
            else std.fmt.bufPrint(&text, "{d} x {d}, {d}.{d:0>3} Hz", .{ selected.view.pixel_w, selected.view.pixel_h, selected.refresh_millihz / 1000, selected.refresh_millihz % 1000 }) catch "";
        _ = canvas.textClipped(12, 181, self.width - 130, &scratch, mode, 0, face);
        _ = canvas.textClipped(12, 219, 88, &scratch, std.fmt.bufPrint(&text, "Scale {d}%", .{ selected.view.scale * 100 / 120 }) catch "", 0, face);
        var status = self.status;
        if (self.client.last_error != 0) status = switch (self.client.last_error) {
            -1 => "Invalid layout. Adjust the display arrangement.", -2 => "A display change is already in progress.",
            -3 => "Display settings are currently unavailable.", -4 => "Displays changed. Refresh before trying again.",
            -5 => "Another settings window owns this confirmation.", -6 => "Settings applied, but saving them failed.",
            -7 => "The requested display mode is not available.", else => "The display change failed.",
        } else switch (self.client.state.phase) {
            1 => status = "Applying display settings...",
            2 => {
                const now = self.sys.monotonicNanoseconds() orelse self.client.state.deadline_ns;
                const seconds = (self.client.state.deadline_ns -| now +| (std.time.ns_per_s - 1)) / std.time.ns_per_s;
                status = std.fmt.bufPrint(&text, "Is the image correct? Reverting in {d} seconds.", .{seconds}) catch "";
            },
            3 => status = "Restoring the previous display settings...",
            4 => status = if (self.client.state.flags & 2 != 0) "Display settings kept." else "Settings kept for this session; monitor identity is unknown.",
            5 => status = "Previous display settings restored.",
            else => {},
        }
        _ = canvas.textClipped(12, self.height - 82, self.width - 24, &scratch, status, 0, face);
        _ = canvas.textClipped(12, self.height - 64, self.width - 24, &scratch, "Each display keeps its own refresh rate.", 0x404040, face);
        for (all_buttons) |button| {
            if (!self.shown(button)) continue;
            const label = switch (button) {
                .monitor => "Next display", .mode_previous => "<", .mode_next => ">", .scale_down => "-", .scale_up => "+",
                .rotate => std.fmt.bufPrint(&text, "Rotate: {d}", .{@as(u32, @intFromEnum(selected.view.rotation)) * 90}) catch "",
                .primary => if (selected.primary) "Primary display" else "Make primary",
                .left => "Left", .right => "Right", .above => "Above", .below => "Below", .clone => "Clone",
                .enabled => if (selected.enabled) "Display enabled" else "Enable display", .refresh => "Refresh", .apply => "Test changes",
                .keep => "Keep", .revert => "Revert", .close => "Close", .colors => "Color settings...", .vrr => "VRR settings...",
            };
            _ = canvas.button(.{ .rect = self.rect(button), .text = label, .focused = self.focus == button,
                .state = if (!self.enabled(button)) .disabled else if (self.pressed == button) .pressed else .normal,
                .is_cancel = button == .revert or button == .close }, &scratch);
        }
        const result = paint.present();
        if (result < 0 and !self.paint_failed) self.sys.println("Display settings: frame submission failed.");
        self.paint_failed = result < 0;
    }
};

/// These scenarios extend the existing Appearance display-control group.
pub fn exercise() !void {
    const t = std.testing;
    const values = [_]topology.Output{
        .{ .key = .{ .adapter = 1, .connector = 1 }, .primary = true, .view = .{ .pixel_w = 1280, .pixel_h = 720 }, .refresh_millihz = 60000 },
        .{ .key = .{ .adapter = 1, .connector = 2 }, .view = .{ .pixel_w = 2560, .pixel_h = 1440, .scale = 240, .origin = .{ .x = 1280 } }, .refresh_millihz = 100000 },
    };
    var app: App = .{ .sys = undefined, .desk = undefined, .draw = undefined, .client = .{},
        .edit = try topology.Layout.init(&values, 1), .selected = 1 };
    app.activate(.clone);
    var wire = control.encode(&app.edit);
    _ = try control.decode(&wire);
    try t.expect(app.edit.outputs[1].clone_group != 0);
    try t.expect(app.edit.outputs[0].interval() != app.edit.outputs[1].interval());
    app.activate(.primary); app.activate(.rotate);
    wire = control.encode(&app.edit);
    try t.expectError(error.Clone, control.decode(&wire));
    app.activate(.left);
    wire = control.encode(&app.edit);
    const moved = try control.normalized(try control.decode(&wire));
    try t.expectEqual(@as(usize, 1), moved.primary);
    try t.expectEqual(topology.Point{}, moved.outputs[1].view.origin);
    try t.expect(moved.outputs[0].view.origin.x > 0);
    try t.expect(!app.enabled(.enabled));
    app.selected = 0; app.activate(.enabled);
    wire = control.encode(&app.edit); _ = try control.decode(&wire);
    try t.expect(!app.edit.outputs[0].enabled and app.edit.outputs[1].enabled);
    app.client.state.phase = 2;
    try t.expect(!app.enabled(.apply) and !app.enabled(.rotate));
    app.client.state.phase = 0;
    app.width = 2400; app.height = 1600;
    try t.expect(app.outputBox(1).w > 0 and app.outputBox(1).h > 0);
}
