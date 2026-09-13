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
}
