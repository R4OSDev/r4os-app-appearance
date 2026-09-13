const std = @import("std");
const r4os = @import("r4os");
const control = @import("display_control.zig");
const a = r4os.abi;
const Button = enum { previous, next, refresh, apply, keep, revert, close };
const face = r4os.gui.default_palette.face;

pub fn run(sys: r4os.r4sys.Context, desk: r4os.r4desk.Context, draw: r4os.r4draw.Context) i32 {
    var app: App = .{ .sys = sys, .desk = desk, .draw = draw };
    return app.run();
}
const App = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    controller: control.Controller = .{},
    width: i32 = 480,
    height: i32 = 360,
    focus: Button = .apply,
    pressed: ?Button = null,
    exiting: bool = false,
    displayed_second: u64 = 0,

    fn run(self: *App) i32 {
        if (self.desk.programWindowId() < 0) { self.sys.println("Display settings requires the Desktop."); return 0; }
        _ = self.desk.guiSetTitle("Display settings");
        _ = self.desk.guiSetMinSize(360, 280);
        defer self.controller.close(&self.draw);
        _ = self.controller.refresh(&self.draw);
        self.metrics(); self.render();
        var events = r4os.EventLoop.init(self.sys, self.desk, &.{});
        while (!self.exiting and !self.sys.programShouldClose()) {
            const timeout = if (self.controller.busy()) r4os.time_contract.timeoutFinite(.{ .nanoseconds = 100 * std.time.ns_per_ms }) else r4os.time_contract.timeoutForever();
            var redraw = false;
            switch (events.wait(timeout)) {
                .message => |message| if (message.guiEvent()) |event| {
                    switch (@as(a.GuiEventKind, @enumFromInt(event.kind))) {
                        .close => self.exiting = true,
                        .resize => { self.metrics(); redraw = true; },
                        .key_down => { self.key(@intCast(event.key & 0xFF)); redraw = true; },
                        .mouse_down => {
                            self.pressed = self.hit(event.x, event.y);
                            if (self.pressed) |target| self.focus = target;
                            redraw = true;
                        },
                        .mouse_up => {
                            const target = self.hit(event.x, event.y);
                            if (target != null and target == self.pressed) self.activate(target.?);
                            self.pressed = null; redraw = true;
                        },
                        else => {},
                    }
                },
                .timed_out => {},
                .failure => |rc| return rc,
            }
            const was_waiting = self.controller.status.phase == a.gfx_mode_phase_awaiting_confirmation;
            if (self.controller.poll(&self.draw)) redraw = true;
            if (!was_waiting and self.controller.status.phase == a.gfx_mode_phase_awaiting_confirmation) {
                self.focus = .revert; self.pressed = null;
            }
            const second = self.seconds();
            if (second != self.displayed_second) { self.displayed_second = second; redraw = true; }
            if (redraw and !self.exiting) self.render();
        }
        return 0;
    }
    fn metrics(self: *App) void {
        var info: a.GuiWindowInfo = .{};
        if (self.desk.guiWindowInfo(&info) >= 0) {
            self.width = @max(360, info.client_w);
            self.height = @max(280, info.client_h);
        }
    }
    fn seconds(self: *const App) u64 {
        if (self.controller.status.phase != a.gfx_mode_phase_awaiting_confirmation) return 0;
        return self.controller.secondsLeft(self.sys.monotonicNanoseconds() orelse return 0);
    }
    fn enabled(self: *const App, target: Button) bool {
        const available = !self.controller.busy();
        return switch (target) {
            .previous, .next => available and self.controller.count > 1,
            .refresh => available,
            .apply => available and self.controller.count != 0,
            .keep => self.controller.status.phase == a.gfx_mode_phase_awaiting_confirmation,
            .revert => self.controller.busy() and self.controller.status.phase != a.gfx_mode_phase_confirming,
            .close => true,
        };
    }
    fn rect(self: *const App, target: Button) r4os.gui.Rect {
        return switch (target) {
            .previous => .{ .x = self.width - 118, .y = 42, .w = 48, .h = 28 },
            .next => .{ .x = self.width - 60, .y = 42, .w = 48, .h = 28 },
            .refresh, .keep => .{ .x = 12, .y = self.height - 40, .w = 90, .h = 28 },
            .apply, .revert => .{ .x = 112, .y = self.height - 40, .w = 106, .h = 28 },
            .close => .{ .x = self.width - 90, .y = self.height - 40, .w = 78, .h = 28 },
        };
    }
    fn buttons(self: *const App) [5]Button {
        return if (self.controller.busy()) .{ .previous, .next, .keep, .revert, .close } else .{ .previous, .next, .refresh, .apply, .close };
    }
    fn hit(self: *const App, x: i32, y: i32) ?Button {
        for (self.buttons()) |target| if (self.enabled(target) and self.rect(target).contains(x, y)) return target;
        return null;
    }
    fn key(self: *App, key_code: u8) void {
        const keys = r4os.gui.Key;
        if (key_code == keys.escape) {
            if (self.controller.busy()) _ = self.controller.resolve(&self.draw, false) else self.exiting = true;
            return;
        }
        if (key_code == keys.left or key_code == keys.right) {
            self.controller.move(if (key_code == keys.left) -1 else 1); return;
        }
        if (key_code == keys.tab or key_code == keys.shift_tab) {
            const targets = self.buttons();
            var index: usize = 0;
            for (targets, 0..) |target, i| if (target == self.focus) { index = i; break; };
            for (0..targets.len) |_| {
                index = if (key_code == keys.shift_tab) (index + targets.len - 1) % targets.len else (index + 1) % targets.len;
                if (self.enabled(targets[index])) { self.focus = targets[index]; break; }
            }
        } else if (key_code == keys.enter or key_code == ' ') self.activate(self.focus);
    }
    fn activate(self: *App, target: Button) void {
        if (!self.enabled(target)) return;
        switch (target) {
            .previous => self.controller.move(-1),
            .next => self.controller.move(1),
            .refresh => _ = self.controller.refresh(&self.draw),
            .apply => {
                if (self.controller.apply(&self.draw)) self.focus = .revert;
            },
            .keep => _ = self.controller.resolve(&self.draw, true),
            .revert => _ = self.controller.resolve(&self.draw, false),
            .close => self.exiting = true,
        }
    }
    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.draw, self.width, self.height)) {
            .paint => |value| value, .failure => return,
        };
        defer paint.discard();
        var commands: [96]a.GuiFrameCommand = undefined;
        var resources: [8192]u8 = undefined;
        var builder: r4os.FrameCanvas = undefined;
        const canvas = paint.bufferedCanvas(&builder, &commands, &resources);
        var scratch: [512]u8 = undefined;
        var label: [128]u8 = undefined;
        _ = canvas.clear(face);
        _ = canvas.textClipped(12, 14, self.width - 24, &scratch, "Resolution and refresh rate (SDR)", 0, face);
        if (self.controller.count != 0) {
            const mode = self.controller.modes[self.controller.selected];
            const text = std.fmt.bufPrint(&label, "{d} x {d}, {d}.{d:0>3} Hz ({d}/{d})",
                .{mode.width,mode.height,mode.refresh_millihz/1000,mode.refresh_millihz%1000,self.controller.selected+1,self.controller.count}) catch "";
            _ = canvas.textClipped(12, 51, self.width - 142, &scratch, text, 0, face);
        } else _ = canvas.textClipped(12, 51, self.width - 142, &scratch, "Current fixed display mode", 0, face);
        const phase = self.controller.status.phase;
        var detail: []const u8 = "Test a mode, then check the image before keeping it.";
        if (self.controller.count == 0) detail = "This output currently offers no switchable SDR modes.";
        if (self.controller.error_code != 0) detail = errorText(self.controller.error_code);
        switch (phase) {
            a.gfx_mode_phase_queued, a.gfx_mode_phase_executing => detail = "Changing display mode...",
            a.gfx_mode_phase_awaiting_confirmation => detail = "Is the image correct? Keep it or revert.",
            a.gfx_mode_phase_confirming => detail = "Keeping this mode...",
            a.gfx_mode_phase_reverting => detail = "Restoring the previous mode...",
            a.gfx_mode_phase_confirmed => detail = "Display mode kept for this session.",
            a.gfx_mode_phase_reverted => if (self.controller.error_code == 0) { detail = "Previous display mode restored."; },
            a.gfx_mode_phase_lost => detail = "Display change failed; recovery is not confirmed.",
            else => {},
        }
        if (self.controller.error_code != 0 and phase != a.gfx_mode_phase_lost) detail = errorText(self.controller.error_code);
        _ = canvas.textClipped(12, 86, self.width - 24, &scratch, detail, 0, face);
        const timer = if (phase == a.gfx_mode_phase_awaiting_confirmation and self.sys.monotonicNanoseconds() == null) "Automatic return is active. Escape reverts."
            else if (phase == a.gfx_mode_phase_awaiting_confirmation)
            std.fmt.bufPrint(&label, "Automatic return in {d} seconds. Escape reverts.", .{self.seconds()}) catch "Automatic return is active."
            else "Color bars, grayscale and checkerboard preview";
        _ = canvas.textClipped(12, 108, self.width - 24, &scratch, timer, 0, face);
        self.pattern(canvas);
        for (self.buttons()) |target| {
            const text: [:0]const u8 = switch (target) {
                .previous => "<", .next => ">", .refresh => "Refresh", .apply => "Test mode",
                .keep => "Keep", .revert => "Revert", .close => "Close",
            };
            _ = canvas.button(.{ .rect = self.rect(target), .text = text,
                .state = if (!self.enabled(target)) .disabled else if (self.pressed == target) .pressed else .normal,
                .focused = self.focus == target, .is_cancel = target == .revert or target == .close }, &scratch);
        }
        _ = paint.present();
    }
    fn pattern(self: *const App, canvas: r4os.gui.Canvas) void {
        const box: r4os.gui.Rect = .{ .x = 12, .y = 136, .w = self.width - 24, .h = self.height - 190 };
        _ = canvas.rect(box, 0xFFFFFF);
        const inner = box.inset(2, 2);
        const half = @divTrunc(inner.h, 2);
        for (control.bars, 0..) |color, index| {
            const i: i32 = @intCast(index);
            const left = @divTrunc(inner.w * i, 8); const right = @divTrunc(inner.w * (i + 1), 8);
            _ = canvas.rect(.{ .x = inner.x + left, .y = inner.y, .w = right-left, .h = half }, color);
        }
        for (0..16) |index| {
            const i: i32 = @intCast(index);
            const left = @divTrunc(inner.w * i, 16); const right = @divTrunc(inner.w * (i + 1), 16);
            _ = canvas.rect(.{ .x = inner.x + left, .y = inner.y + half, .w = right-left, .h = @divTrunc(inner.h-half,2) }, @as(u32,@intCast(i*17))*0x010101);
            for (0..2) |row| {
                const top = half + @divTrunc(inner.h-half,2) + @divTrunc((inner.h-half-@divTrunc(inner.h-half,2))*@as(i32,@intCast(row)),2);
                const bottom = half + @divTrunc(inner.h-half,2) + @divTrunc((inner.h-half-@divTrunc(inner.h-half,2))*@as(i32,@intCast(row+1)),2);
                _ = canvas.rect(.{ .x = inner.x+left, .y = inner.y+top, .w = right-left, .h = bottom-top }, if ((index+row)%2==0) 0xFFFFFF else 0);
            }
        }
    }
};
fn errorText(code: i32) []const u8 {
    return switch (code) {
        a.gfx_output_error_stale => "Display changed. Refresh the available modes.",
        a.gfx_output_error_busy => "Another display change is still running.",
        a.gfx_output_error_timeout => "The change timed out; check the current display state.",
        a.gfx_output_error_unsupported, a.gfx_output_error_bandwidth => "This display mode cannot be applied.",
        else => "Display settings are currently unavailable.",
    };
}
