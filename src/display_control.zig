//! App-owned selection and confirmation policy over the common display API.
//! The kernel owns accepted BO references and the rollback timer.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub const confirmation_ms = 15000;
pub const bars = [_]u32{ 0xFFFFFF, 0xFFFF00, 0x00FFFF, 0x00FF00, 0xFF00FF, 0xFF0000, 0x0000FF, 0x000000 };

pub const Controller = struct {
    output: ?a.GfxOutputInfo = null,
    modes: [a.gfx_output_max_modes]a.GfxOutputMode = @splat(.{}),
    count: usize = 0,
    selected: usize = 0,
    status: a.GfxModeStatus = .{},
    error_code: i32 = 0,
    buffer: a.GfxBufferReference = .{},
    mapping: a.GfxBufferMap = .{},
    close_requested: bool = false,

    pub fn busy(self: *const Controller) bool {
        return self.status.ticket != 0 and self.status.phase != a.gfx_mode_phase_confirmed and self.status.phase != a.gfx_mode_phase_reverted;
    }
    pub fn refresh(self: *Controller, draw: anytype) bool {
        if (self.busy()) return false;
        const previous = self.output;
        const previous_mode = if (self.count != 0) self.modes[self.selected].mode_id else 0;
        var preserved = false;
        self.output = null; self.count = 0; self.selected = 0; self.error_code = 0;
        const outputs = draw.outputs();
        var before: a.GfxDisplayRevision = .{};
        const rc = outputs.revision(&before);
        if (rc != a.gfx_output_ok) { self.error_code = rc; return false; }
        if (before.present > before.capacity or before.capacity > 32) { self.error_code = a.gfx_output_error_capacity; return false; }
        for (0..before.present) |i| {
            var info: a.GfxOutputInfo = .{};
            const result = outputs.info(@intCast(i), &info);
            if (result != a.gfx_output_ok or info.topology_revision != before.revision) {
                self.error_code = if (result == a.gfx_output_ok) a.gfx_output_error_stale else result; return false;
            }
            const flags = a.gfx_output_flag_connected | a.gfx_output_flag_active;
            if (info.flags & flags != flags or info.flags & (a.gfx_output_flag_receiver_only | a.gfx_output_flag_fixed_geometry) != 0 or
                info.limits.flags & a.gfx_output_limit_modeset == 0) continue;
            if (self.output != null) { self.output = null; self.error_code = a.gfx_output_error_unsupported; return false; }
            self.output = info;
        }
        const info = self.output orelse return false;
        if (info.mode_count > self.modes.len or info.possible_heads == 0 or info.possible_planes == 0 or info.possible_plls == 0) {
            self.output = null; self.error_code = a.gfx_output_error_capacity; return false;
        }
        for (0..info.mode_count) |i| {
            var mode: a.GfxOutputMode = .{};
            const result = outputs.mode(&info.identity, @intCast(i), &mode);
            if (result != a.gfx_output_ok) { self.output = null; self.count = 0; self.error_code = result; return false; }
            // This UI requests only the admitted progressive RGB8 SDR path.
            if (mode.flags & (a.gfx_output_mode_geometry_only | a.gfx_output_mode_interlaced | a.gfx_output_mode_420_only) != 0 or
                mode.width == 0 or mode.height == 0 or mode.pixel_clock_hz == 0) continue;
            self.modes[self.count] = mode;
            if (!preserved and mode.mode_id == info.preferred_mode_id) self.selected = self.count;
            if (previous != null and std.meta.eql(previous.?.identity, info.identity) and mode.mode_id == previous_mode) {
                self.selected = self.count; preserved = true;
            }
            self.count += 1;
        }
        var after: a.GfxDisplayRevision = .{};
        if (outputs.revision(&after) != a.gfx_output_ok or after.revision != before.revision) {
            self.output = null; self.count = 0; self.error_code = a.gfx_output_error_stale; return false;
        }
        return self.count != 0;
    }
    pub fn move(self: *Controller, direction: i32) void {
        if (self.busy() or self.count == 0) return;
        if (direction < 0) self.selected = (self.selected + self.count - 1) % self.count else self.selected = (self.selected + 1) % self.count;
    }
    pub fn apply(self: *Controller, draw: anytype) bool {
        if (self.busy() or self.count == 0 or !self.cleanup(draw)) return false;
        self.error_code = 0;
        const info = self.output orelse return false;
        const mode = self.modes[self.selected];
        const pitch = @as(u64, mode.width) * 4;
        const bytes = std.math.mul(u64, pitch, mode.height) catch { self.error_code = a.gfx_output_error_overflow; return false; };
        if (bytes > std.math.maxInt(usize)) { self.error_code = a.gfx_output_error_overflow; return false; }
        const descriptor: a.GfxBufferDescriptor = .{ .width = mode.width, .height = mode.height, .byte_length = bytes,
            .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1, .plane_pitches = .{pitch,0,0,0},
            .usage = a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_scanout };
        var rc = draw.gfxBufferCreate(&descriptor, &self.buffer);
        if (rc != a.gfx_buffer_result_ok) { self.error_code = rc; return false; }
        defer _ = self.cleanup(draw);
        rc = draw.gfxBufferMap(&self.buffer.reference, a.gfx_buffer_map_write, 0, bytes, &self.mapping);
        if (rc != a.gfx_buffer_result_ok) { self.error_code = rc; return false; }
        const pixels: [*]u32 = @ptrFromInt(self.mapping.cpu_address);
        fillPattern(pixels[0..@intCast(bytes / 4)], mode.width, mode.height);
        rc = draw.gfxBufferUnmap(&self.mapping.lease);
        if (rc != a.gfx_buffer_result_ok) { self.error_code = rc; return false; }
        self.mapping = .{};
        var request: a.GfxAtomicState = .{ .topology_revision = info.topology_revision, .count = 1 };
        request.assignments[0] = .{ .output = info.identity, .mode_id = mode.mode_id,
            .head_id = @ctz(info.possible_heads), .plane_id = @ctz(info.possible_planes), .pll_id = @ctz(info.possible_plls),
            .source_width = mode.width, .source_height = mode.height, .destination_width = mode.width, .destination_height = mode.height,
            .buffer = self.buffer.reference };
        const outputs = draw.outputs();
        var checked: a.GfxAtomicResult = .{};
        rc = outputs.testState(&request, &checked);
        if (rc != a.gfx_output_ok) { self.error_code = rc; return false; }
        var accepted: a.GfxModeStatus = .{};
        rc = outputs.submit(&request, confirmation_ms, &accepted);
        if (rc != a.gfx_output_ok) { self.error_code = rc; return false; }
        self.status = accepted; self.close_requested = false;
        return true;
    }
    pub fn poll(self: *Controller, draw: anytype) bool {
        if (!self.busy()) return false;
        var next: a.GfxModeStatus = .{};
        const rc = draw.outputs().status(self.status.ticket, &next);
        if (rc != a.gfx_output_ok or next.ticket != self.status.ticket or !std.meta.eql(next.output, self.status.output)) {
            const error_code = if (rc == a.gfx_output_ok) a.gfx_output_error_stale else rc;
            const changed = self.error_code != error_code; self.error_code = error_code; return changed;
        }
        const changed = !std.meta.eql(next, self.status);
        self.status = next;
        self.error_code = next.error_code;
        if (!self.busy()) {
            _ = self.refresh(draw);
            if (next.error_code != 0) self.error_code = next.error_code;
        }
        if (self.close_requested and next.phase == a.gfx_mode_phase_awaiting_confirmation) _ = self.resolve(draw, false);
        return changed;
    }
    pub fn resolve(self: *Controller, draw: anytype, confirm: bool) bool {
        if (!self.busy() or (confirm and self.status.phase != a.gfx_mode_phase_awaiting_confirmation)) return false;
        var next: a.GfxModeStatus = .{};
        const rc = draw.outputs().resolve(self.status.ticket, if (confirm) a.gfx_mode_resolve_confirm else a.gfx_mode_resolve_rollback, &next);
        if (rc != a.gfx_output_ok) { self.error_code = rc; return false; }
        self.status = next; self.error_code = next.error_code;
        return true;
    }
    pub fn close(self: *Controller, draw: anytype) void {
        self.close_requested = true;
        if (self.busy() and self.status.phase != a.gfx_mode_phase_confirming) _ = self.resolve(draw, false);
        _ = self.cleanup(draw);
    }
    pub fn cleanup(self: *Controller, draw: anytype) bool {
        if (self.mapping.lease.id != 0) {
            const rc = draw.gfxBufferUnmap(&self.mapping.lease);
            if (rc != a.gfx_buffer_result_ok) { self.error_code = rc; return false; }
            self.mapping = .{};
        }
        if (self.buffer.reference.id != 0) {
            const rc = draw.gfxBufferRelease(&self.buffer.reference);
            if (rc != a.gfx_buffer_result_ok) { self.error_code = rc; return false; }
            self.buffer = .{};
        }
        return true;
    }
    pub fn secondsLeft(self: *const Controller, now: u64) u64 {
        const remaining = self.status.confirmation_deadline_ns -| now;
        return (remaining / std.time.ns_per_s) + @intFromBool(remaining % std.time.ns_per_s != 0);
    }
};

pub fn fillPattern(pixels: []u32, width: u32, height: u32) void {
    std.debug.assert(width != 0 and height != 0 and pixels.len == @as(u64, width) * height);
    for (0..height) |y| {
        for (0..width) |x| {
            const color = if (x == 0 or y == 0 or x + 1 == width or y + 1 == height) @as(u32, 0xFFFFFF)
                else if (y < height / 2) bars[@min(bars.len - 1, x * bars.len / width)]
                else if (y < @as(u64, height) * 3 / 4) blk: {
                    const gray: u32 = @intCast(x * 255 / @max(width - 1, 1));
                    break :blk gray * 0x010101;
                } else if ((x / 8 + y / 8) % 2 == 0) @as(u32, 0xFFFFFF) else 0;
            pixels[y * width + x] = color;
        }
    }
}
