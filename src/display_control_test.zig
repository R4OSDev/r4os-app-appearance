//! Existing Appearance model entrypoint; only the ABI transport is modeled.
const std = @import("std");
const a = @import("r4os").abi;
const control = @import("display_control.zig");
const t = std.testing;
const identity: a.GfxOutputId = .{ .adapter_id = 17, .connector_id = 3, .device_generation = 7, .connection_generation = 9 };
const Fake = struct {
    fixed: bool = false,
    drift: bool = false,
    revision_calls: usize = 0,
    creates: u32 = 0,
    releases: u32 = 0,
    submissions: u32 = 0,
    decisions: u32 = 0,
    decision: u32 = 0,
    test_error: i32 = 0,
    creator: bool = false,
    mapped: bool = false,
    retained: bool = false,
    pixels: [24*16]u32 = @splat(0xEEEEEEEE),
    descriptor: a.GfxBufferDescriptor = .{},
    reference: a.GfxBufferReference = .{},
    current: a.GfxModeStatus = .{},
    pub fn outputs(self: *Fake) *Fake { return self; }
    pub fn revision(self: *Fake, out: *a.GfxDisplayRevision) i32 {
        self.revision_calls += 1;
        out.* = .{ .revision = if (self.drift and self.revision_calls > 1) 11 else 10, .present = 1 };
        return a.gfx_output_ok;
    }
    pub fn info(self: *Fake, index: u32, out: *a.GfxOutputInfo) i32 {
        std.debug.assert(index == 0);
        out.* = .{ .identity = identity, .topology_revision = 10,
            .flags = a.gfx_output_flag_connected | a.gfx_output_flag_active | (if (self.fixed) a.gfx_output_flag_fixed_geometry else @as(u32,0)),
            .mode_count = 2, .preferred_mode_id = 1, .possible_heads = 4, .possible_planes = 8, .possible_plls = 4,
            .limits = .{ .flags = a.gfx_output_limit_modeset } };
        return a.gfx_output_ok;
    }
    pub fn mode(_: *Fake, output: *const a.GfxOutputId, index: u32, out: *a.GfxOutputMode) i32 {
        std.debug.assert(std.meta.eql(output.*,identity) and index < 2);
        out.* = .{ .mode_id = index+1, .width = if(index==0)16 else 24, .height = if(index==0)8 else 16,
            .pixel_clock_hz = 1_000_000, .refresh_millihz = 60000 };
        return a.gfx_output_ok;
    }
    pub fn gfxBufferCreate(self: *Fake, d: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) i32 {
        std.debug.assert(!self.creator and !self.mapped and d.byte_length <= self.pixels.len*4 and
            d.format == a.gfx_buffer_format_xrgb8888 and d.location == a.gfx_buffer_location_system and
            d.byte_length == @as(u64,d.width)*4*d.height and d.plane_pitches[0] == @as(u64,d.width)*4 and
            d.usage & a.gfx_buffer_usage_scanout != 0);
        self.creates += 1; self.creator = true; self.descriptor = d.*;
        self.reference = .{ .reference = .{ .id = self.creates+5, .generation = 3 }, .buffer = .{ .id = self.creates+99, .generation = 7 } };
        out.* = self.reference;
        return a.gfx_buffer_result_ok;
    }
    pub fn gfxBufferMap(self: *Fake, reference: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, out: *a.GfxBufferMap) i32 {
        std.debug.assert(self.creator and !self.mapped and std.meta.eql(reference.*,self.reference.reference) and
            access == a.gfx_buffer_map_write and offset==0 and bytes == self.descriptor.byte_length);
        self.mapped = true; out.* = .{ .lease = .{ .id=7,.generation=1 }, .cpu_address=@intFromPtr(&self.pixels) };
        return a.gfx_buffer_result_ok;
    }
    pub fn gfxBufferUnmap(self: *Fake, lease: *const a.GfxBufferHandle) i32 {
        std.debug.assert(self.mapped and lease.id == 7);
        self.mapped = false; return a.gfx_buffer_result_ok;
    }
    pub fn gfxBufferRelease(self: *Fake, reference: *const a.GfxBufferHandle) i32 {
        std.debug.assert(self.creator and !self.mapped and std.meta.eql(reference.*,self.reference.reference));
        self.creator = false; self.releases += 1; return a.gfx_buffer_result_ok;
    }
    pub fn testState(self: *Fake, request: *const a.GfxAtomicState, _: *a.GfxAtomicResult) i32 {
        std.debug.assert(request.count==1 and request.topology_revision==10 and self.creator and !self.mapped);
        const state = request.assignments[0];
        std.debug.assert(std.meta.eql(state.output,identity) and state.head_id==2 and state.plane_id==3 and state.pll_id==2 and
            std.meta.eql(state.buffer,self.reference.reference) and state.source_width==self.descriptor.width and
            state.source_height==self.descriptor.height and state.destination_width==state.source_width and state.destination_height==state.source_height);
        const width: usize = self.descriptor.width; const height: usize = self.descriptor.height;
        std.debug.assert(self.pixels[0]==0xFFFFFF and self.pixels[width*height-1]==0xFFFFFF and
            self.pixels[width+width/2]==control.bars[4] and self.pixels[(height/2)*width+1]==(255/(width-1))*0x010101);
        return if(self.test_error!=0) self.test_error else a.gfx_output_ok;
    }
    pub fn submit(self: *Fake, _: *const a.GfxAtomicState, ms: u32, out: *a.GfxModeStatus) i32 {
        std.debug.assert(self.creator and !self.mapped and ms == 15000);
        self.submissions += 1; self.retained = true;
        self.current = .{ .ticket=self.submissions, .phase=a.gfx_mode_phase_queued, .output=identity, .retained=3 };
        out.* = self.current; return a.gfx_output_ok;
    }
    pub fn status(self: *Fake, ticket: u64, out: *a.GfxModeStatus) i32 {
        std.debug.assert(ticket == self.current.ticket and self.retained);
        out.* = self.current; return a.gfx_output_ok;
    }
    pub fn resolve(self: *Fake, ticket: u64, action: u32, out: *a.GfxModeStatus) i32 {
        std.debug.assert(ticket==self.current.ticket and !self.creator and self.retained);
        self.decisions+=1; self.decision=action;
        self.current.phase=if(action==a.gfx_mode_resolve_confirm) a.gfx_mode_phase_confirming else a.gfx_mode_phase_reverting;
        out.*=self.current; return a.gfx_output_ok;
    }
};
pub fn exercise() !void {
    var fake: Fake = .{};
    var ui: control.Controller = .{};
    try t.expect(ui.refresh(&fake) and ui.count==2);
    ui.move(-1); try t.expect(ui.selected==1);
    try t.expect(ui.apply(&fake) and ui.busy() and fake.creates==1 and fake.releases==1 and !fake.creator and !fake.mapped and fake.retained);
    try t.expect(!ui.resolve(&fake,true) and fake.decisions==0);
    const chosen=ui.selected; ui.move(1); try t.expect(ui.selected==chosen and !ui.apply(&fake) and fake.creates==1);
    fake.current.phase=a.gfx_mode_phase_awaiting_confirmation;
    fake.current.confirmation_deadline_ns=20*std.time.ns_per_s;
    try t.expect(ui.poll(&fake) and ui.secondsLeft(5*std.time.ns_per_s)==15 and ui.secondsLeft(20*std.time.ns_per_s)==0 and fake.decisions==0);
    try t.expect(ui.resolve(&fake,true) and ui.busy() and fake.decision==a.gfx_mode_resolve_confirm);
    fake.current.phase=a.gfx_mode_phase_confirmed;
    try t.expect(ui.poll(&fake) and !ui.busy() and fake.retained);
    try t.expect(ui.refresh(&fake) and ui.apply(&fake));
    ui.close(&fake);
    try t.expect(ui.close_requested and ui.busy() and fake.decision==a.gfx_mode_resolve_rollback and fake.releases==2 and fake.retained);
    fake.current.phase=a.gfx_mode_phase_reverted;
    try t.expect(ui.poll(&fake) and !ui.busy());
    fake.test_error=a.gfx_output_error_bandwidth;
    try t.expect(ui.refresh(&fake) and !ui.apply(&fake) and fake.submissions==2 and fake.creates==3 and fake.releases==3 and !fake.creator and !fake.mapped);
    fake.fixed=true;
    try t.expect(!ui.refresh(&fake) and ui.count==0 and !ui.apply(&fake) and fake.creates==3);
    fake.fixed=false; fake.drift=true; fake.revision_calls=0;
    try t.expect(!ui.refresh(&fake) and ui.count==0 and ui.error_code==a.gfx_output_error_stale);
    var pixel: [1]u32 = undefined; control.fillPattern(&pixel,1,1); try t.expectEqual(@as(u32,0xFFFFFF),pixel[0]);
    try exerciseColor();
}

// This fixture checks the two-BO transaction and CMM call, not color math.
// The existing R4GFX/Desktop groups compare actual pixel conversion numerically.
const gfx = @import("r4gfx");
const ColorFake = struct {
    base: Fake = .{},
    pixels: [24 * 16]u32 = @splat(0),
    creator: bool = false,
    mapped: bool = false,
    releases: u32 = 0,
    request: a.GfxModeColorRequest = .{},
    pub fn outputs(self: *ColorFake) *ColorFake { return self; }
    pub fn revision(self: *ColorFake, out: *a.GfxDisplayRevision) i32 { return self.base.revision(out); }
    pub fn info(self: *ColorFake, index: u32, out: *a.GfxOutputInfo) i32 { return self.base.info(index, out); }
    pub fn mode(self: *ColorFake, output: *const a.GfxOutputId, index: u32, out: *a.GfxOutputMode) i32 { return Fake.mode(&self.base, output, index, out); }
    pub fn gfxBufferCreate(self: *ColorFake, descriptor: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) i32 {
        if (descriptor.format == a.gfx_buffer_format_xrgb8888) return self.base.gfxBufferCreate(descriptor, out);
        std.debug.assert(!self.creator and self.base.mapped and descriptor.format == a.gfx_buffer_format_xrgb2101010 and
            descriptor.byte_length == self.base.descriptor.byte_length and descriptor.usage == a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source);
        self.creator = true;
        out.* = .{ .reference = .{ .id = 99, .generation = 3 }, .buffer = .{ .id = 199, .generation = 7 } };
        return a.gfx_buffer_result_ok;
    }
    pub fn gfxBufferMap(self: *ColorFake, ref: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, out: *a.GfxBufferMap) i32 {
        if (ref.id != 99) return self.base.gfxBufferMap(ref, access, offset, bytes, out);
        std.debug.assert(self.creator and !self.mapped and access == a.gfx_buffer_map_write and offset == 0 and bytes == self.base.descriptor.byte_length);
        self.mapped = true; out.* = .{ .lease = .{ .id = 99, .generation = 1 }, .cpu_address = @intFromPtr(&self.pixels) }; return a.gfx_buffer_result_ok;
    }
    pub fn gfxBufferUnmap(self: *ColorFake, lease: *const a.GfxBufferHandle) i32 {
        if (lease.id != 99) return self.base.gfxBufferUnmap(lease);
        std.debug.assert(self.mapped); self.mapped = false; return a.gfx_buffer_result_ok;
    }
    pub fn gfxBufferRelease(self: *ColorFake, ref: *const a.GfxBufferHandle) i32 {
        if (ref.id != 99) return self.base.gfxBufferRelease(ref);
        std.debug.assert(self.creator and !self.mapped); self.creator = false; self.releases += 1; return a.gfx_buffer_result_ok;
    }
    pub fn testColor(self: *ColorFake, request: *const a.GfxModeColorRequest, out: *a.GfxAtomicResult) i32 {
        std.debug.assert(self.creator and !self.mapped and request.image.id == 99 and request.image.generation == 3 and request.state.assignments[0].buffer.id != 99);
        std.debug.assert(request.signal.transfer == 3 and request.signal.bpc == 10 and self.pixels[0] == 0xA579);
        return self.base.testState(&request.state, out);
    }
    pub fn submitColor(self: *ColorFake, request: *const a.GfxModeColorRequest, ms: u32, out: *a.GfxModeStatus) i32 {
        self.request = request.*; return self.base.submit(&request.state, ms, out);
    }
    pub fn status(self: *ColorFake, ticket: u64, out: *a.GfxModeStatus) i32 { return self.base.status(ticket, out); }
    pub fn resolve(self: *ColorFake, ticket: u64, action: u32, out: *a.GfxModeStatus) i32 { return self.base.resolve(ticket, action, out); }
};
const Colors = struct {
    fail: bool = false,
    pub fn color_description_validate(_: Colors, description: *const gfx.R4GfxColorDescription) i32 {
        std.debug.assert(description.alpha == gfx.color_alpha_opaque and description.precision == 10 and description.transfer == 3); return 0;
    }
    pub fn color_image_transform(self: Colors, source: *const gfx.R4GfxColorImage, target: *const gfx.R4GfxColorImage,
        request: *const gfx.R4GfxColorTransform, _: *gfx.R4GfxCpuStats) i32
    {
        std.debug.assert(source.image.cpu_address != target.image.cpu_address and source.description.transfer == 1 and source.description.precision == 8 and
            target.description.transfer == 3 and target.description.reference_white == 2_030_000 and request.opacity == 65535 and request.flags == 7);
        if (self.fail) return -7;
        const pixels: [*]u32 = @ptrFromInt(target.image.cpu_address);
        @memset(pixels[0..@intCast(target.image.byte_length / 4)], 0xA579); return 0;
    }
};
fn exerciseColor() !void {
    var fake: ColorFake = .{};
    var ui: control.Controller = .{};
    try t.expect(ui.refresh(&fake));
    const signal: a.GfxColorSignal = .{ .format = a.gfx_buffer_format_xrgb2101010, .bpc = 10, .primaries = 3, .transfer = 3, .range = 2,
        .pipeline = 7, .reference_white = 2_030_000, .peak = 10_000_000, .metadata_valid = 1 };
    try t.expect(ui.applyColor(gfx, &fake, Colors{}, signal));
    try t.expect(fake.releases == 1 and fake.base.releases == 1 and !fake.creator and !fake.base.creator and !fake.mapped and !fake.base.mapped);
    try t.expectEqualDeep(signal, fake.request.signal);
    ui.close(&fake);
    try t.expect(fake.base.decision == a.gfx_mode_resolve_rollback);
    fake.base.current.phase = a.gfx_mode_phase_reverted; _ = ui.poll(&fake);
    try t.expect(!ui.applyColor(gfx, &fake, Colors{ .fail = true }, signal));
    try t.expect(fake.base.submissions == 1 and fake.releases == 2 and fake.base.releases == 2 and !fake.creator and !fake.base.creator and !fake.mapped and !fake.base.mapped);
}
