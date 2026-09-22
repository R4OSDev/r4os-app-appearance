//! Appearance owns edits to the boot policy. Preserve unrelated boot lines,
//! and compare the exact old content in the kernel's atomic replacement.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const checks = r4os.system_update_recovery;
pub const path = "C:\\CONFIG.R4S";
pub const max_bytes = 2048;
pub const Choice = enum { automatic, software };

pub fn read(sys: *const r4os.r4sys.Context, bytes: *[max_bytes]u8) ![]const u8 {
    const info = sys.fileInfo(path) orelse return error.Read;
    if (info.is_dir != 0 or info.size == 0 or info.size > bytes.len) return error.Size;
    const count = sys.fileRead(path, bytes);
    if (count < 0 or @as(u64, @intCast(count)) != info.size) return error.Read;
    return bytes[0..@intCast(count)];
}

pub fn selected(bytes: []const u8) Choice {
    var result: Choice = .automatic;
    var lines = std.mem.tokenizeAny(u8, stripBom(bytes), "\r\n");
    while (lines.next()) |line| if (value(line)) |part| {
        result = if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), "AUTO")) .automatic else .software;
    };
    return result;
}
fn stripBom(bytes: []const u8) []const u8 { return if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[3..] else bytes; }
fn value(line: []const u8) ?[]const u8 {
    const content = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t");
    if (content.len < 9 or !std.ascii.eqlIgnoreCase(content[0..9], "GRAPHICS=")) return null;
    return content[9..];
}
fn graphicsDriverMode(line: []const u8) ?[]const u8 {
    const content = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t");
    if (content.len < 7 or !std.ascii.eqlIgnoreCase(content[0..7], "OPTION ")) return null;
    const rest = std.mem.trim(u8, content[7..], " \t");
    const separator = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
    const driver = rest[0..separator];
    // These two driver owners implement the shared auto/passive/native mode
    // policy. Other drivers' unrelated mode options must remain unchanged.
    if (!std.ascii.eqlIgnoreCase(driver, "NVIDIA") and !std.ascii.eqlIgnoreCase(driver, "AMDGPU")) return null;
    const option = rest[separator + 1 ..];
    const equals = std.mem.indexOfScalar(u8, option, '=') orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, option[0..equals], " \t"), "mode")) return null;
    // AMD auto deliberately stays passive until board qualification. Keep a
    // user's explicit native admission across Software -> Automatic changes.
    if (std.ascii.eqlIgnoreCase(driver, "AMDGPU") and
        std.ascii.eqlIgnoreCase(std.mem.trim(u8, option[equals + 1 ..], " \t"), "native")) return null;
    return driver;
}
pub fn rewrite(bytes: []const u8, choice: Choice, out: *[max_bytes]u8) ![]const u8 {
    if (bytes.len == 0 or bytes.len > max_bytes or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.Size;
    var written: usize = 0;
    const body = stripBom(bytes);
    try append(out, &written, bytes[0 .. bytes.len - body.len]);
    var start: usize = 0;
    var found = false;
    while (start < body.len) {
        var end = start;
        while (end < body.len and body[end] != '\r' and body[end] != '\n') : (end += 1) {}
        const line = body[start..end];
        const graphics_line = value(line) != null;
        const driver_mode = if (choice == .automatic) graphicsDriverMode(line) else null;
        if (graphics_line or driver_mode != null) {
            found = found or graphics_line;
            if (graphics_line) {
                try append(out, &written, if (choice == .automatic) "GRAPHICS=AUTO" else "GRAPHICS=SOFTWARE");
            } else {
                try append(out, &written, "OPTION ");
                try append(out, &written, driver_mode.?);
                try append(out, &written, " mode=auto");
            }
            if (std.mem.indexOfScalar(u8, line, '#')) |comment| {
                try append(out, &written, " "); try append(out, &written, line[comment..]);
            }
        } else try append(out, &written, line);
        start = end;
        while (end < body.len and (body[end] == '\r' or body[end] == '\n')) : (end += 1) {}
        try append(out, &written, body[start..end]); start = end;
    }
    if (!found) {
        if (written != 0 and out[written - 1] != '\n' and out[written - 1] != '\r') try append(out, &written, "\r\n");
        try append(out, &written, if (choice == .automatic) "GRAPHICS=AUTO\r\n" else "GRAPHICS=SOFTWARE\r\n");
    }
    return out[0..written];
}
fn append(out: []u8, at: *usize, bytes: []const u8) !void {
    if (bytes.len > out.len - at.*) return error.Size;
    @memcpy(out[at.*..][0..bytes.len], bytes); at.* += bytes.len;
}

pub fn save(sys: *const r4os.r4sys.Context, choice: Choice) !void {
    var original: [max_bytes]u8 = undefined;
    const old = try read(sys, &original);
    var changed: [max_bytes]u8 = undefined;
    const next = try rewrite(old, choice, &changed);
    if (std.mem.eql(u8, old, next)) return;
    var stage_buffer: [32]u8 = undefined;
    var backup_buffer: [32]u8 = undefined;
    const seed: u32 = @truncate(sys.ticks() ^ @intFromPtr(&original));
    for (0..64) |attempt| {
        const id = (seed +% @as(u32, @intCast(attempt))) & 0xffffff;
        const stage = try std.fmt.bufPrintZ(&stage_buffer, "C:\\GP{X:0>6}.TMP", .{id});
        const backup = try std.fmt.bufPrintZ(&backup_buffer, "C:\\GP{X:0>6}.BAK", .{id});
        var info: a.FileInfo = .{};
        const rc = sys.fileInfoRaw(backup, &info);
        if (rc > 0) continue;
        if (rc < 0) return error.Read;
        const files: r4os.app_storage.Files = .{ .sys = sys.* };
        var writer = switch (files.streamWriter(.{ .ptr = stage, .len = @intCast(stage.len) }, a.file_stream_open_create)) {
            .writer => |w| w,
            .failure => |code| {
                if (code == a.file_stream_error_exists) continue;
                _ = sys.fileStreamAbort(stage); return error.Write;
            },
        };
        if (writer.write(next) != .ok or writer.finish() != .ok) { _ = writer.abort(); return error.Write; }
        const result = sys.fileUpdateAtomicChecked(path, stage, backup, next.len, checks.checksum(next), old.len, checks.checksum(old),
            r4os.r4sys.file_update_atomic_checked_flag_forward | r4os.r4sys.file_update_atomic_checked_flag_target_existed |
            r4os.r4sys.file_update_atomic_checked_flag_old_known);
        // Ambiguous I/O can follow publication. Preserve both copies then;
        // never recover by overwriting CONFIG or deleting an unverified copy.
        if (result != 0) return error.Replace;
        _ = sys.fileDeleteIfMatch(backup, old.len, checks.checksum(old));
        return;
    }
    return error.Busy;
}

pub fn exercise() !void {
    const t = std.testing;
    var out: [max_bytes]u8 = undefined;
    const original = "\xEF\xBB\xBF# boot\r\nGRAPHICS=AUTO # keep\r\nDRIVER=NVIDIA\r\nOPTION NVIDIA mode=native\ngraphics=bad\nAUTO=PCI";
    const result = try rewrite(original, .software, &out);
    try t.expectEqualStrings("\xEF\xBB\xBF# boot\r\nGRAPHICS=SOFTWARE # keep\r\nDRIVER=NVIDIA\r\nOPTION NVIDIA mode=native\nGRAPHICS=SOFTWARE\nAUTO=PCI", result);
    try t.expectEqual(Choice.software, selected(result));
    try t.expectEqualStrings("OPTION NVIDIA mode=auto # old passive\nOPTION SID model=8580\nGRAPHICS=AUTO\r\n",
        try rewrite("OPTION NVIDIA mode=passive # old passive\nOPTION SID model=8580\n", .automatic, &out));
    try t.expectEqualStrings("OPTION amdgpu mode=auto # panel\nOPTION NVIDIA mode=auto\nOPTION SID mode=6581\nOPTION AMDGPU power=balanced\nGRAPHICS=AUTO\r\n",
        try rewrite("OPTION amdgpu\tmode = passive # panel\nOPTION NVIDIA mode=native\nOPTION SID mode=6581\nOPTION AMDGPU power=balanced\n", .automatic, &out));
    try t.expectEqualStrings("OPTION AMDGPU mode=native\nGRAPHICS=SOFTWARE\r\n",
        try rewrite("OPTION AMDGPU mode=native\n", .software, &out));
    var intermediate: [max_bytes]u8 = undefined;
    const native = "GRAPHICS=AUTO\r\n  OPTION amdgpu\tmode = NaTiVe # qualified panel\r\n";
    const software = try rewrite(native, .software, &intermediate);
    try t.expectEqualStrings(native, try rewrite(software, .automatic, &out));
    try t.expectEqual(Choice.automatic, selected(try rewrite("#GRAPHICS=SOFTWARE\nAUTO=PCI", .automatic, &out)));
    const full: [max_bytes]u8 = @splat('x');
    try t.expectError(error.Size, rewrite(&full, .software, &out));
    try t.expectError(error.Size, rewrite("AUTO=PCI\x00", .automatic, &out));
}
