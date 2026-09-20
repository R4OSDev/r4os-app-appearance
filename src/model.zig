const std = @import("std");

test "display selection retains common ownership and waits for real decisions" {
    try @import("display_control_test.zig").exercise();
    try @import("display_settings.zig").exercise();
    try @import("graphics_policy.zig").exercise();
    const r4os = @import("r4os");
    const a = r4os.abi;
    const original: a.DisplayStateInfo = .{ .revision = 5, .device_generation = 7, .driver_owner = 2, .adapter_id = 0x01000100 };
    var changed = original; changed.device_generation += 1;
    try std.testing.expect(!r4os.graphics_status.sameOwner(original, changed));
    changed = original; changed.revision += 1;
    try std.testing.expect(!r4os.graphics_status.sameOwner(original, changed));
    var status: r4os.graphics_status.Snapshot = .{ .display = original };
    var line: [224]u8 = undefined;
    try std.testing.expectEqualStrings("Loaded driver version: unavailable", status.line(&line, 2));
    try std.testing.expect(!status.matchesAdapter(.{ .flags = 1, .bus_no = 2 }));
    try std.testing.expect(status.matchesAdapter(.{ .flags = 1, .bus_no = 1 }));
    status.display.capabilities = 0;
    try std.testing.expectEqualStrings("Software fallback: unavailable", status.line(&line, 6));
}

pub const default_desktop_bg: u32 = 0x008080;
pub const default_desktop_icon_text: u32 = 0xFFFFFF;
pub const background_signal_prefix = "R4OS_APPEARANCE_BG=";
pub const reload_signal = "R4OS_APPEARANCE_RELOAD=1";
pub const max_wallpaper_width: u32 = 4096;
pub const max_wallpaper_height: u32 = 2160;

pub const palette = [_]u32{
    0x000000, 0x808080, 0xC0C0C0, 0xFFFFFF,
    0x800000, 0xFF0000, 0x808000, 0xFFFF00,
    0x008000, 0x00FF00, 0x008080, 0x00FFFF,
    0x000080, 0x0000FF, 0x800080, 0xFF00FF,
};

pub fn parseRgb24(text: []const u8) ?u32 {
    if (text.len != 6) return null;
    var value: u32 = 0;
    for (text) |ch| {
        value = (value << 4) | (hexValue(ch) orelse return null);
    }
    return value;
}

pub fn formatRgb24(out: []u8, value: u32) bool {
    if (out.len < 6) return false;
    const digits = "0123456789ABCDEF";
    var shift: u5 = 20;
    var index: usize = 0;
    while (index < 6) : (index += 1) {
        out[index] = digits[@intCast((value >> shift) & 0xF)];
        if (shift >= 4) shift -= 4;
    }
    return true;
}

pub fn formatBackgroundSignal(out: []u8, value: u32) ?usize {
    const needed = background_signal_prefix.len + 6;
    if (out.len <= needed) return null;
    @memcpy(out[0..background_signal_prefix.len], background_signal_prefix);
    if (!formatRgb24(out[background_signal_prefix.len..needed], value)) return null;
    out[needed] = 0;
    return needed;
}

pub fn parseBackgroundSignal(text: []const u8) ?u32 {
    if (text.len != background_signal_prefix.len + 6) return null;
    if (!std.mem.eql(u8, text[0..background_signal_prefix.len], background_signal_prefix)) return null;
    return parseRgb24(text[background_signal_prefix.len..]);
}

pub fn hasWallpaperExtension(path: []const u8) bool {
    if (path.len < 4) return false;
    const extension = path[path.len - 4 ..];
    return std.ascii.eqlIgnoreCase(extension, ".BMP") or std.ascii.eqlIgnoreCase(extension, ".PNG");
}

pub fn wallpaperDimensionsAllowed(width: u32, height: u32) bool {
    return width > 0 and height > 0 and width <= max_wallpaper_width and height <= max_wallpaper_height;
}

fn hexValue(ch: u8) ?u32 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    return null;
}

fn asciiUpper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - ('a' - 'A') else ch;
}

test "RGB text is strict and case insensitive" {
    try std.testing.expectEqual(@as(?u32, 0x008080), parseRgb24("008080"));
    try std.testing.expectEqual(@as(?u32, 0xA1B2C3), parseRgb24("a1B2c3"));
    try std.testing.expectEqual(@as(?u32, null), parseRgb24("12345"));
    try std.testing.expectEqual(@as(?u32, null), parseRgb24("12G456"));
}

test "RGB formatting is six uppercase digits" {
    var out: [6]u8 = undefined;
    try std.testing.expect(formatRgb24(out[0..], 0x12ABEF));
    try std.testing.expectEqualStrings("12ABEF", out[0..]);
}

test "background signal has an exact contract" {
    var out: [40]u8 = .{0} ** 40;
    const len = formatBackgroundSignal(out[0..], 0x336699) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("R4OS_APPEARANCE_BG=336699", out[0..len]);
    try std.testing.expectEqual(@as(?u32, 0x336699), parseBackgroundSignal(out[0..len]));
    try std.testing.expectEqual(@as(?u32, null), parseBackgroundSignal("R4OS_APPEARANCE_BG=336699X"));
}

test "wallpaper filter accepts BMP and PNG extensions" {
    try std.testing.expect(hasWallpaperExtension("C:\\WALL.BMP"));
    try std.testing.expect(hasWallpaperExtension("D:\\Images\\sky.bmp"));
    try std.testing.expect(hasWallpaperExtension("C:\\WALL.PNG"));
    try std.testing.expect(hasWallpaperExtension("D:\\Images\\sky.png"));
    try std.testing.expect(!hasWallpaperExtension("C:\\WALL.PNG.BAK"));
    try std.testing.expect(!hasWallpaperExtension("BMP"));
}

test "wallpaper dimensions include Full HD and enforce the decode bound" {
    try std.testing.expect(wallpaperDimensionsAllowed(1920, 1080));
    try std.testing.expect(wallpaperDimensionsAllowed(4096, 2160));
    try std.testing.expect(!wallpaperDimensionsAllowed(4097, 2160));
    try std.testing.expect(!wallpaperDimensionsAllowed(640, 0));
}
