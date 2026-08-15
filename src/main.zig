const r4os = @import("r4os");
const r4img = @import("r4img");
const r4std = @import("r4std");
const model = @import("model.zig");

const AppApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    img: r4img.Context,

    fn init(r4_app: *r4os.App) ?AppApi {
        return .{
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .draw = r4_app.drawing() orelse return null,
            .img = r4img.Context.init(r4_app.startContext()) orelse return null,
        };
    }
};

const FocusTarget = enum(u8) {
    tabs,
    swatches,
    rgb,
    browse,
    none,
    apply,
    ok,
    cancel,
};

const ColorTarget = enum(u8) {
    background,
    icon_text,
};

const color_tabs = [_]r4os.gui.TabItem{
    .{ .text = "Background" },
    .{ .text = "Icon text" },
};

const app_bg = r4os.gui.default_palette.face;
const text_color = r4os.gui.default_palette.text;
const status_bg: u32 = 0xD8D8D8;
const swatch_size: i32 = 26;
const swatch_gap: i32 = 4;
const swatch_columns: usize = 8;
const path_capacity: usize = r4os.path.file_path_max + 1;
const dir_buffer_capacity: usize = 4096;
const max_dir_items: usize = 96;
const dir_item_capacity: usize = 96;
const max_wallpaper_file_bytes: usize = 32 * 1024 * 1024;

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    if (!r4std.init(r4_app.startContext())) return r4os.abi.err_no_group;
    var ctx = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(ctx.sys.argsRaw(), "/SELFTEST")) return runSelfTest(&ctx.sys);
    var app = App{ .ctx = &ctx };
    return app.run();
}

const App = struct {
    ctx: *AppApi,
    w: i32 = 480,
    h: i32 = 400,
    should_exit: bool = false,
    selected_color: u32 = model.default_desktop_bg,
    saved_color: u32 = model.default_desktop_bg,
    icon_text_color: u32 = model.default_desktop_icon_text,
    saved_icon_text_color: u32 = model.default_desktop_icon_text,
    active_target: ColorTarget = .background,
    selected_swatch: ?usize = 10,
    rgb: r4os.gui.TextField(7) = .{},
    focus: FocusTarget = .tabs,
    pressed: ?FocusTarget = null,
    status: [96]u8 = .{0} ** 96,
    wallpaper_path: [path_capacity]u8 = .{0} ** path_capacity,
    saved_wallpaper_path: [path_capacity]u8 = .{0} ** path_capacity,
    dialog_open: bool = false,
    dialog_selected_index: usize = 0,
    dialog_first_index: usize = 0,
    dialog_hover_index: ?usize = null,
    dialog_pressed_action: r4os.gui.DialogAction = .none,
    current_dir: [path_capacity]u8 = .{0} ** path_capacity,
    selected_path: [path_capacity]u8 = .{0} ** path_capacity,
    dirbuf: [dir_buffer_capacity]u8 = .{0} ** dir_buffer_capacity,
    dir_items: [max_dir_items][dir_item_capacity]u8 = .{.{0} ** dir_item_capacity} ** max_dir_items,
    dir_item_slices: [max_dir_items][]const u8 = [_][]const u8{""} ** max_dir_items,
    dir_source_indexes: [max_dir_items]u32 = .{0} ** max_dir_items,
    dir_item_count: usize = 0,

    fn run(self: *App) i32 {
        if (self.ctx.desk.programWindowId() < 0) {
            self.ctx.sys.println("APPEARANCE is a desktop GUI application.");
            return 0;
        }
        _ = self.ctx.desk.guiSetTitle("Appearance");
        _ = self.ctx.desk.guiSetMinSize(480, 400);
        self.load();
        self.updateMetrics();
        self.render();

        while (!self.ctx.sys.programShouldClose() and !self.should_exit) {
            var event: r4os.abi.GuiEvent = .{};
            while (self.ctx.desk.guiPollEvent(&event) > 0) {
                const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
                switch (kind) {
                    .close => return 0,
                    .resize => {
                        self.updateMetrics();
                        self.render();
                    },
                    .mouse_down => self.handleMouseDown(event.x, event.y),
                    .mouse_up => self.handleMouseUp(event.x, event.y),
                    .key_down => self.handleKey(@intCast(event.key & 0xFF)),
                    else => {},
                }
            }
            self.ctx.sys.sleepTicks(3);
        }
        return 0;
    }

    fn load(self: *App) void {
        var color = model.default_desktop_bg;
        const rc = r4std.config.readRgb24(&self.ctx.sys, r4std.settings.paths.desktop, "DESKTOP_BG", model.default_desktop_bg, &color);
        var icon_text_color = model.default_desktop_icon_text;
        const icon_rc = r4std.config.readRgb24(&self.ctx.sys, r4std.settings.paths.desktop, "DESKTOP_ICON_TEXT", model.default_desktop_icon_text, &icon_text_color);
        var wallpaper_value: [path_capacity]u8 = .{0} ** path_capacity;
        const wallpaper_rc = r4std.config.readString(&self.ctx.sys, r4std.settings.paths.desktop, "WALLPAPER", "NONE", wallpaper_value[0..]);
        self.selected_color = color;
        self.saved_color = color;
        self.icon_text_color = icon_text_color;
        self.saved_icon_text_color = icon_text_color;
        self.selected_swatch = paletteIndex(color);
        if (wallpaper_rc >= 0 and !equalsIgnoreCase(spanZ(wallpaper_value[0..]), "NONE")) {
            const parsed = r4os.path.AbsoluteFilePath.parse(spanZ(wallpaper_value[0..])) catch null;
            if (parsed) |path| {
                if (model.hasBmpExtension(path.bytes())) setZ(self.wallpaper_path[0..], path.bytes());
            }
        }
        setZ(self.saved_wallpaper_path[0..], spanZ(self.wallpaper_path[0..]));
        self.setCurrentDirFromPath(spanZ(self.wallpaper_path[0..]));
        self.updateRgbText();
        self.setStatus(if (rc < 0 or icon_rc < 0 or wallpaper_rc < 0) "Could not read desktop settings." else "Choose a desktop color, icon text color or BMP wallpaper.");
    }

    fn updateMetrics(self: *App) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        self.w = clampI32(info.client_w, 480, 900);
        self.h = clampI32(info.client_h, 400, 760);
    }

    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.ctx.draw, self.w, self.h)) {
            .paint => |value| value,
            .failure => return,
        };
        defer paint.discard();
        const canvas = paint.canvas;
        var scratch: [512]u8 = .{0} ** 512;
        var title_buf: [24]u8 = .{0} ** 24;
        var preview_label: [24]u8 = .{0} ** 24;
        var color_label: [24]u8 = .{0} ** 24;
        var wallpaper_label: [24]u8 = .{0} ** 24;

        self.rgb.focused = self.focus == .rgb;
        _ = canvas.clear(app_bg);
        _ = self.tabBar().draw(canvas, scratch[0..]);
        _ = canvas.groupBox(.{ .rect = self.groupRect(), .title = copyLit(title_buf[0..], "Desktop appearance") }, scratch[0..]);
        _ = canvas.label(.{ .rect = .{ .x = 28, .y = 66, .w = 150, .h = 18 }, .text = copyLit(preview_label[0..], "Preview"), .fg = text_color, .bg = app_bg }, scratch[0..]);
        self.drawPreview(canvas, scratch[0..]);
        self.drawSwatches(canvas);
        _ = canvas.label(.{ .rect = .{ .x = 218, .y = 150, .w = 82, .h = 18 }, .text = copyLit(color_label[0..], "RGB color:"), .fg = text_color, .bg = app_bg }, scratch[0..]);
        _ = self.rgb.draw(canvas, self.rgbRect(), scratch[0..]);
        _ = canvas.label(.{ .rect = .{ .x = 28, .y = 228, .w = 120, .h = 18 }, .text = copyLit(wallpaper_label[0..], "Wallpaper (BMP):"), .fg = text_color, .bg = app_bg }, scratch[0..]);
        self.drawWallpaperPath(canvas, scratch[0..]);
        self.drawButton(canvas, scratch[0..], self.browseRect(), "Browse...", .browse, false);
        self.drawButton(canvas, scratch[0..], self.noneRect(), "None", .none, false);

        _ = canvas.rect(self.statusRect(), status_bg);
        _ = canvas.textClipped(self.statusRect().x + 6, self.statusRect().y + 4, self.statusRect().w - 12, scratch[0..], spanZ(self.status[0..]), text_color, status_bg);
        self.drawButton(canvas, scratch[0..], self.applyRect(), "Apply", .apply, false);
        self.drawButton(canvas, scratch[0..], self.okRect(), "OK", .ok, true);
        self.drawButton(canvas, scratch[0..], self.cancelRect(), "Cancel", .cancel, false);
        if (self.dialog_open) _ = canvas.fileDialog(self.fileDialog(), scratch[0..]);
        _ = paint.present();
    }

    fn drawWallpaperPath(self: *const App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.wallpaperPathRect();
        _ = canvas.rect(rect, r4os.gui.default_palette.face_shadow);
        _ = canvas.rect(rect.inset(1, 1), r4os.gui.default_palette.face_light);
        const inner = rect.inset(2, 2);
        _ = canvas.rect(inner, 0xFFFFFF);
        const value = if (self.wallpaper_path[0] == 0) "None" else spanZ(self.wallpaper_path[0..]);
        _ = canvas.textClipped(inner.x + 4, inner.y + 4, inner.w - 8, scratch, value, text_color, 0xFFFFFF);
    }

    fn drawPreview(self: *const App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const outer = self.previewRect();
        _ = canvas.rect(outer, 0x000000);
        const bezel = outer.inset(2, 2);
        _ = canvas.rect(bezel, 0xC0C0C0);
        const desktop = bezel.inset(3, 3);
        _ = canvas.rect(desktop, self.selected_color);
        const normal_label = r4os.gui.Rect{ .x = desktop.x + 5, .y = desktop.y + 6, .w = 61, .h = 14 };
        _ = canvas.textClipped(normal_label.x, normal_label.y, normal_label.w, scratch, "Computer", self.icon_text_color, self.selected_color);
        const selected_label = r4os.gui.Rect{ .x = desktop.x + 72, .y = desktop.y + 4, .w = 64, .h = 18 };
        _ = canvas.rect(selected_label, 0x000080);
        _ = canvas.textClipped(selected_label.x + 2, selected_label.y + 2, selected_label.w - 4, scratch, "Selected", 0xFFFFFF, 0x000080);
        const sample = r4os.gui.Rect{ .x = desktop.x + 24, .y = desktop.y + 32, .w = desktop.w - 48, .h = desktop.h - 42 };
        _ = canvas.rect(sample, 0xFFFFFF);
        _ = canvas.rect(.{ .x = sample.x, .y = sample.y, .w = sample.w, .h = 14 }, 0x000080);
        _ = canvas.rect(.{ .x = sample.x + 8, .y = sample.y + 24, .w = sample.w - 16, .h = 5 }, 0xC0C0C0);
    }

    fn drawSwatches(self: *const App, canvas: r4os.gui.Canvas) void {
        for (model.palette, 0..) |color, index| {
            const rect = self.swatchRect(index);
            const selected = self.selected_swatch != null and self.selected_swatch.? == index;
            _ = canvas.rect(rect, if (selected) 0x000000 else 0x808080);
            _ = canvas.rect(rect.inset(2, 2), if (selected and self.focus == .swatches) 0xFFFFFF else 0xC0C0C0);
            _ = canvas.rect(rect.inset(4, 4), color);
        }
    }

    fn drawButton(self: *const App, canvas: r4os.gui.Canvas, scratch: []u8, rect: r4os.gui.Rect, label: []const u8, target: FocusTarget, is_default: bool) void {
        var label_buf: [16]u8 = .{0} ** 16;
        _ = canvas.button(.{
            .rect = rect,
            .text = copyZ(label_buf[0..], label),
            .state = if (self.pressed == target) .pressed else .normal,
            .focused = self.focus == target,
            .is_default = is_default,
            .is_cancel = target == .cancel,
        }, scratch);
    }

    fn handleMouseDown(self: *App, x: i32, y: i32) void {
        if (self.dialog_open) {
            self.handleFileDialogMouseDown(x, y);
            self.render();
            return;
        }
        if (self.tabBar().indexAt(x, y)) |index| {
            if (!self.selectColorTarget(@enumFromInt(index))) {
                self.render();
                return;
            }
            self.focus = .tabs;
            self.render();
            return;
        }
        if (self.swatchAt(x, y)) |index| {
            self.selectSwatch(index);
            self.focus = .swatches;
            self.render();
            return;
        }
        if (self.rgbRect().contains(x, y)) {
            self.focus = .rgb;
            self.pressed = null;
            self.render();
            return;
        }
        inline for (.{ FocusTarget.browse, FocusTarget.none, FocusTarget.apply, FocusTarget.ok, FocusTarget.cancel }) |target| {
            if (self.buttonRect(target).contains(x, y)) {
                self.focus = target;
                self.pressed = target;
                self.render();
                return;
            }
        }
    }

    fn handleMouseUp(self: *App, x: i32, y: i32) void {
        if (self.dialog_open) {
            self.handleFileDialogMouseUp(x, y);
            self.render();
            return;
        }
        const target = self.pressed orelse return;
        self.pressed = null;
        if (self.buttonRect(target).contains(x, y)) self.activate(target);
        if (!self.should_exit) self.render();
    }

    fn handleKey(self: *App, key: u8) void {
        if (self.dialog_open) {
            self.handleFileDialogKey(key);
            self.render();
            return;
        }
        if (key == r4os.gui.Key.escape) {
            self.should_exit = true;
            return;
        }
        if (key == r4os.gui.Key.tab or key == r4os.gui.Key.shift_tab) {
            self.advanceFocus(key == r4os.gui.Key.shift_tab);
            self.render();
            return;
        }
        if (self.focus == .rgb) {
            if (key == r4os.gui.Key.enter) {
                _ = self.acceptRgbText();
            } else if (self.rgb.handleClipboardKey(&self.ctx.desk, key)) {
                self.selected_swatch = null;
                self.setStatus("Press Apply to save the color.");
            }
            self.render();
            return;
        }
        if (self.focus == .tabs) {
            const step = self.tabBar().keyAction(key);
            if (step.index != @intFromEnum(self.active_target)) _ = self.selectColorTarget(@enumFromInt(step.index));
            self.render();
            return;
        }
        if (self.focus == .swatches) {
            const current = self.selected_swatch orelse 0;
            var next = current;
            if (key == r4os.gui.Key.left and current > 0) next -= 1;
            if (key == r4os.gui.Key.right and current + 1 < model.palette.len) next += 1;
            if (key == r4os.gui.Key.up and current >= swatch_columns) next -= swatch_columns;
            if (key == r4os.gui.Key.down and current + swatch_columns < model.palette.len) next += swatch_columns;
            if (next != current) self.selectSwatch(next);
            self.render();
            return;
        }
        if (key == r4os.gui.Key.enter or key == ' ') {
            self.activate(self.focus);
            if (!self.should_exit) self.render();
        }
    }

    fn activate(self: *App, target: FocusTarget) void {
        switch (target) {
            .browse => self.openWallpaperDialog(),
            .none => {
                @memset(self.wallpaper_path[0..], 0);
                self.setStatus("Wallpaper disabled. Press Apply to save.");
            },
            .apply => self.apply(false),
            .ok => self.apply(true),
            .cancel => self.should_exit = true,
            .rgb => _ = self.acceptRgbText(),
            .tabs => {},
            .swatches => {},
        }
    }

    fn apply(self: *App, close_on_success: bool) void {
        if (!self.acceptRgbText()) return;
        if (self.wallpaper_path[0] != 0 and !self.validateWallpaper(spanZ(self.wallpaper_path[0..]))) return;
        var color_text: [6]u8 = undefined;
        var icon_text: [6]u8 = undefined;
        if (!model.formatRgb24(color_text[0..], self.selected_color) or !model.formatRgb24(icon_text[0..], self.icon_text_color)) {
            self.setStatus("Could not format the desktop colors.");
            return;
        }
        const wallpaper_value = if (self.wallpaper_path[0] == 0) "NONE" else spanZ(self.wallpaper_path[0..]);
        const rc = saveAppearanceConfig(&self.ctx.sys, r4std.settings.paths.desktop, color_text[0..], icon_text[0..], wallpaper_value);
        if (rc < 0) {
            self.setStatus("Could not save desktop settings.");
            return;
        }
        var signal: [40]u8 = .{0} ** 40;
        setZ(signal[0..], model.reload_signal);
        if (self.ctx.desk.guiSetText(@ptrCast(&signal)) < 0) {
            self.setStatus("Saved, but Desktop notification failed.");
            return;
        }
        self.saved_color = self.selected_color;
        self.saved_icon_text_color = self.icon_text_color;
        setZ(self.saved_wallpaper_path[0..], spanZ(self.wallpaper_path[0..]));
        self.setStatus("Desktop appearance saved.");
        if (close_on_success) self.should_exit = true;
    }

    fn acceptRgbText(self: *App) bool {
        const parsed = model.parseRgb24(self.rgb.value()) orelse {
            self.setStatus("Enter exactly six hexadecimal RGB digits.");
            return false;
        };
        self.setActiveColor(parsed);
        self.selected_swatch = paletteIndex(parsed);
        self.updateRgbText();
        self.setStatus("Press Apply to save the color.");
        return true;
    }

    fn selectSwatch(self: *App, index: usize) void {
        if (index >= model.palette.len) return;
        self.selected_swatch = index;
        self.setActiveColor(model.palette[index]);
        self.updateRgbText();
        self.setStatus("Press Apply to save the color.");
    }

    fn updateRgbText(self: *App) void {
        var value: [6]u8 = undefined;
        _ = model.formatRgb24(value[0..], self.activeColor());
        self.rgb.set(value[0..]);
    }

    fn advanceFocus(self: *App, reverse: bool) void {
        const count: u8 = 8;
        const current: u8 = @intFromEnum(self.focus);
        const next = if (reverse) (current + count - 1) % count else (current + 1) % count;
        self.focus = @enumFromInt(next);
    }

    fn activeColor(self: *const App) u32 {
        return switch (self.active_target) {
            .background => self.selected_color,
            .icon_text => self.icon_text_color,
        };
    }

    fn setActiveColor(self: *App, value: u32) void {
        switch (self.active_target) {
            .background => self.selected_color = value,
            .icon_text => self.icon_text_color = value,
        }
    }

    fn selectColorTarget(self: *App, target: ColorTarget) bool {
        if (target == self.active_target) return true;
        if (!self.acceptRgbText()) return false;
        self.active_target = target;
        self.selected_swatch = paletteIndex(self.activeColor());
        self.updateRgbText();
        self.setStatus(if (target == .background) "Editing the desktop background color." else "Editing the desktop icon text color.");
        return true;
    }

    fn swatchAt(self: *const App, x: i32, y: i32) ?usize {
        var index: usize = 0;
        while (index < model.palette.len) : (index += 1) {
            if (self.swatchRect(index).contains(x, y)) return index;
        }
        return null;
    }

    fn openWallpaperDialog(self: *App) void {
        if (self.current_dir[0] == 0) setZ(self.current_dir[0..], "C:\\");
        if (!self.loadDirectory()) {
            self.setStatus("Could not read the wallpaper directory.");
            return;
        }
        self.dialog_open = true;
        self.dialog_selected_index = 0;
        self.dialog_first_index = 0;
        self.dialog_hover_index = null;
        self.dialog_pressed_action = .none;
        self.setStatus("Choose a 24-bit or 32-bit BMP file.");
    }

    fn closeWallpaperDialog(self: *App, status_text: []const u8) void {
        self.dialog_open = false;
        self.dialog_pressed_action = .none;
        self.setStatus(status_text);
    }

    fn loadDirectory(self: *App) bool {
        @memset(self.dirbuf[0..], 0);
        self.dir_item_count = 0;
        const read = self.ctx.sys.dirList(zptr(self.current_dir[0..]), self.dirbuf[0 .. self.dirbuf.len - 1]);
        if (read < 0) return false;
        const length: usize = @min(@as(usize, @intCast(read)), self.dirbuf.len - 1);
        var start: usize = 0;
        var source_index: u32 = 0;
        var index: usize = 0;
        while (index <= length) : (index += 1) {
            if (index != length and self.dirbuf[index] != '\n') continue;
            var end = index;
            while (end > start and (self.dirbuf[end - 1] == '\r' or self.dirbuf[end - 1] == '\n')) end -= 1;
            if (end > start) self.addFilteredDirItem(self.dirbuf[start..end], source_index);
            source_index += 1;
            start = index + 1;
        }
        return true;
    }

    fn addFilteredDirItem(self: *App, text: []const u8, source_index: u32) void {
        if (self.dir_item_count >= max_dir_items) return;
        var resolved: [path_capacity]u8 = .{0} ** path_capacity;
        const kind = self.ctx.sys.dirEntry(zptr(self.current_dir[0..]), source_index, resolved[0 .. resolved.len - 1]);
        if (kind < 0) return;
        if (kind == 0 and !model.hasBmpExtension(spanZ(resolved[0..]))) return;
        const target = self.dir_item_count;
        const count = @min(text.len, dir_item_capacity - 1);
        @memset(self.dir_items[target][0..], 0);
        if (count > 0) @memcpy(self.dir_items[target][0..count], text[0..count]);
        self.dir_item_slices[target] = self.dir_items[target][0..count];
        self.dir_source_indexes[target] = source_index;
        self.dir_item_count += 1;
    }

    fn fileDialog(self: *const App) r4os.gui.FileDialog {
        return .{
            .rect = self.fileDialogRect(),
            .title = "Select Wallpaper",
            .path = spanZ(self.current_dir[0..]),
            .items = self.dir_item_slices[0..self.dir_item_count],
            .mode = .open,
            .ok_text = "Open",
            .cancel_text = "Cancel",
            .selected_index = @min(self.dialog_selected_index, if (self.dir_item_count == 0) 0 else self.dir_item_count - 1),
            .hover_index = self.dialog_hover_index,
            .first_index = self.dialog_first_index,
            .focus_action = .select,
            .pressed_action = self.dialog_pressed_action,
        };
    }

    fn resolveDirEntry(self: *App, display_index: usize) i32 {
        if (display_index >= self.dir_item_count) return -1;
        @memset(self.selected_path[0..], 0);
        const source_index = self.dir_source_indexes[display_index];
        const kind = self.ctx.sys.dirEntry(zptr(self.current_dir[0..]), source_index, self.selected_path[0 .. self.selected_path.len - 1]);
        self.selected_path[self.selected_path.len - 1] = 0;
        return kind;
    }

    fn selectDirEntry(self: *App, display_index: usize) void {
        const kind = self.resolveDirEntry(display_index);
        if (kind < 0) {
            self.setStatus("Could not resolve the selected item.");
            return;
        }
        if (kind > 0) {
            setZ(self.current_dir[0..], spanZ(self.selected_path[0..]));
            if (self.loadDirectory()) {
                self.dialog_selected_index = 0;
                self.dialog_first_index = 0;
                self.setStatus("Choose a BMP wallpaper.");
            } else {
                self.setStatus("Could not open the selected folder.");
            }
            return;
        }
        self.setStatus("Press Open to use the selected BMP.");
    }

    fn acceptDialogSelection(self: *App) void {
        if (self.dir_item_count == 0) {
            self.setStatus("No BMP file is available in this folder.");
            return;
        }
        const kind = self.resolveDirEntry(self.dialog_selected_index);
        if (kind < 0) {
            self.setStatus("Could not resolve the selected item.");
            return;
        }
        if (kind > 0) {
            self.selectDirEntry(self.dialog_selected_index);
            return;
        }
        if (!self.validateWallpaper(spanZ(self.selected_path[0..]))) return;
        setZ(self.wallpaper_path[0..], spanZ(self.selected_path[0..]));
        self.setCurrentDirFromPath(spanZ(self.wallpaper_path[0..]));
        self.closeWallpaperDialog("BMP selected. Press Apply to save.");
    }

    fn handleFileDialogKey(self: *App, key: u8) void {
        if (key == r4os.gui.Key.escape) {
            self.closeWallpaperDialog("Wallpaper selection cancelled.");
            return;
        }
        const dialog = self.fileDialog();
        switch (dialog.keyAction(key)) {
            .ok => self.acceptDialogSelection(),
            .cancel => self.closeWallpaperDialog("Wallpaper selection cancelled."),
            .previous, .next => |action| {
                self.dialog_selected_index = dialog.selectedIndexForAction(action);
                self.dialog_first_index = self.fileDialog().firstIndexForSelection();
            },
            else => {},
        }
    }

    fn handleFileDialogMouseDown(self: *App, x: i32, y: i32) void {
        const dialog = self.fileDialog();
        const action = dialog.actionAt(x, y);
        if (action == .select) {
            if (dialog.indexAt(x, y)) |index| {
                self.dialog_selected_index = index;
                self.dialog_first_index = self.fileDialog().firstIndexForSelection();
                self.selectDirEntry(index);
            }
            return;
        }
        self.dialog_pressed_action = action;
    }

    fn handleFileDialogMouseUp(self: *App, x: i32, y: i32) void {
        const dialog = self.fileDialog();
        const action = dialog.actionAt(x, y);
        const pressed_action = self.dialog_pressed_action;
        self.dialog_pressed_action = .none;
        if (action != pressed_action) return;
        switch (action) {
            .ok => self.acceptDialogSelection(),
            .cancel => self.closeWallpaperDialog("Wallpaper selection cancelled."),
            else => {},
        }
    }

    fn validateWallpaper(self: *App, path: []const u8) bool {
        if (!model.hasBmpExtension(path)) {
            self.setStatus("Only .BMP wallpaper files are supported.");
            return false;
        }
        var path_storage: [path_capacity]u8 = .{0} ** path_capacity;
        setZ(path_storage[0..], path);
        const info = self.ctx.sys.fileInfo(zptr(path_storage[0..])) orelse {
            self.setStatus("The selected wallpaper file is missing.");
            return false;
        };
        if (info.is_dir != 0 or info.size == 0 or info.size > max_wallpaper_file_bytes) {
            self.setStatus("The BMP wallpaper is empty or too large.");
            return false;
        }
        const length: usize = @intCast(info.size);
        const allocator = self.ctx.sys.allocator();
        const bytes = allocator.alloc(u8, length) catch {
            self.setStatus("Not enough memory to check the BMP wallpaper.");
            return false;
        };
        defer allocator.free(bytes);
        const read = self.ctx.sys.fileRead(zptr(path_storage[0..]), bytes);
        if (read != @as(i32, @intCast(length))) {
            self.setStatus("Could not read the BMP wallpaper.");
            return false;
        }
        const image_info = self.ctx.img.probe(bytes, "image/bmp") catch {
            self.setStatus("BMP is invalid or unsupported by R4IMG.");
            return false;
        };
        if (image_info.format != .bmp) {
            self.setStatus("The selected file is not a BMP image.");
            return false;
        }
        if (!model.wallpaperDimensionsAllowed(image_info.width, image_info.height)) {
            self.setStatus("BMP exceeds the 4096 x 2160 wallpaper limit.");
            return false;
        }
        return true;
    }

    fn setCurrentDirFromPath(self: *App, path: []const u8) void {
        if (path.len == 0) {
            setZ(self.current_dir[0..], "C:\\");
            return;
        }
        const separator = lastPathSeparator(path) orelse {
            setZ(self.current_dir[0..], "C:\\");
            return;
        };
        const end = if (separator == 2) 3 else separator;
        setZ(self.current_dir[0..], path[0..end]);
    }

    fn groupRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 12, .y = 36, .w = self.w - 24, .h = self.h - 126 };
    }

    fn tabBar(self: *const App) r4os.gui.TabBar {
        return .{
            .rect = .{ .x = 18, .y = 12, .w = self.w - 36, .h = 24 },
            .items = color_tabs[0..],
            .selected_index = @intFromEnum(self.active_target),
            .focused = self.focus == .tabs,
            .tab_h = 24,
        };
    }

    fn previewRect(self: *const App) r4os.gui.Rect {
        _ = self;
        return .{ .x = 28, .y = 88, .w = 150, .h = 118 };
    }

    fn swatchRect(self: *const App, index: usize) r4os.gui.Rect {
        _ = self;
        const column: i32 = @intCast(index % swatch_columns);
        const row: i32 = @intCast(index / swatch_columns);
        return .{
            .x = 218 + column * (swatch_size + swatch_gap),
            .y = 82 + row * (swatch_size + swatch_gap),
            .w = swatch_size,
            .h = swatch_size,
        };
    }

    fn rgbRect(self: *const App) r4os.gui.Rect {
        _ = self;
        return .{ .x = 304, .y = 146, .w = 82, .h = 24 };
    }

    fn wallpaperPathRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 28, .y = 250, .w = @max(120, self.w - 200), .h = 24 };
    }

    fn browseRect(self: *const App) r4os.gui.Rect {
        return .{ .x = self.w - 162, .y = 250, .w = 76, .h = 24 };
    }

    fn noneRect(self: *const App) r4os.gui.Rect {
        return .{ .x = self.w - 76, .y = 250, .w = 58, .h = 24 };
    }

    fn fileDialogRect(self: *const App) r4os.gui.Rect {
        return r4os.gui.centeredRect(.{ .x = 0, .y = 0, .w = self.w, .h = self.h }, @min(456, self.w - 24), @min(340, self.h - 36));
    }

    fn statusRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 12, .y = self.h - 82, .w = self.w - 24, .h = 26 };
    }

    fn buttonY(self: *const App) i32 {
        return self.h - 42;
    }

    fn applyRect(self: *const App) r4os.gui.Rect {
        return .{ .x = self.w - 260, .y = self.buttonY(), .w = 72, .h = 24 };
    }

    fn okRect(self: *const App) r4os.gui.Rect {
        return .{ .x = self.w - 176, .y = self.buttonY(), .w = 72, .h = 24 };
    }

    fn cancelRect(self: *const App) r4os.gui.Rect {
        return .{ .x = self.w - 92, .y = self.buttonY(), .w = 80, .h = 24 };
    }

    fn buttonRect(self: *const App, target: FocusTarget) r4os.gui.Rect {
        return switch (target) {
            .browse => self.browseRect(),
            .none => self.noneRect(),
            .apply => self.applyRect(),
            .ok => self.okRect(),
            .cancel => self.cancelRect(),
            else => .{},
        };
    }

    fn setStatus(self: *App, value: []const u8) void {
        setZ(self.status[0..], value);
    }
};

fn runSelfTest(ctx: *const r4os.r4sys.Context) i32 {
    const path = "D:\\APPEAR.R4S";
    defer {
        _ = ctx.fileDelete(path);
        _ = ctx.fileDelete("D:\\APPEAR.R4S.TMP");
        _ = ctx.fileDelete("D:\\APPEAR.R4S.BAK");
    }
    if (ctx.fileWrite(path, "WALLPAPER=NONE\r\nDESKTOP_BG=008080\r\nDESKTOP_ICON_TEXT=FFFFFF\r\n") < 0) return selfTestFail(ctx, "fixture-write");
    if (saveAppearanceConfig(ctx, path, "336699", "FFD700", "D:\\WALL.BMP") < 0) return selfTestFail(ctx, "config-write");
    var bytes: [256]u8 = undefined;
    const len = ctx.fileRead(path, bytes[0..]);
    if (len <= 0) return selfTestFail(ctx, "config-read");
    const content = bytes[0..@intCast(len)];
    if (!contains(content, "WALLPAPER=D:\\WALL.BMP") or !contains(content, "WALLPAPER_MODE=CENTER") or !contains(content, "DESKTOP_BG=336699") or !contains(content, "DESKTOP_ICON_TEXT=FFD700")) return selfTestFail(ctx, "config-values");
    var signal: [40]u8 = .{0} ** 40;
    const signal_len = model.formatBackgroundSignal(signal[0..], 0x336699) orelse return selfTestFail(ctx, "signal-format");
    if (model.parseBackgroundSignal(signal[0..signal_len]) != 0x336699) return selfTestFail(ctx, "signal-parse");
    if (!equalsIgnoreCase(model.reload_signal, "R4OS_APPEARANCE_RELOAD=1")) return selfTestFail(ctx, "reload-signal");
    ctx.println("APPEARANCE selftest: OK");
    return 0;
}

fn selfTestFail(ctx: *const r4os.r4sys.Context, label: []const u8) i32 {
    ctx.write("APPEARANCE selftest FAILED: ");
    ctx.println(label);
    return 1;
}

fn saveAppearanceConfig(ctx: *const r4os.r4sys.Context, path: [*:0]const u8, color: []const u8, icon_text: []const u8, wallpaper: []const u8) i32 {
    var existing: [r4std.config.max_file_bytes]u8 = undefined;
    const read = ctx.fileRead(path, existing[0..]);
    const has_existing = read > 0 and read <= @as(i32, @intCast(existing.len));
    const existing_bytes = if (has_existing) existing[0..@as(usize, @intCast(read))] else existing[0..0];

    var output: [r4std.config.max_output_bytes]u8 = undefined;
    var writer = r4std.settings.Writer.init(output[0..]);
    writer.writeHeader("DESKTOP");
    if (has_existing) {
        var iterator = r4std.settings.EntryIterator.init(existing_bytes);
        while (iterator.next()) |entry| {
            if (r4std.settings.equalsKey(entry.key, r4std.settings.format_key)) continue;
            if (r4std.settings.equalsKey(entry.key, r4std.settings.schema_key)) continue;
            if (r4std.settings.equalsKey(entry.key, "DESKTOP_BG")) continue;
            if (r4std.settings.equalsKey(entry.key, "DESKTOP_ICON_TEXT")) continue;
            if (r4std.settings.equalsKey(entry.key, "WALLPAPER")) continue;
            if (r4std.settings.equalsKey(entry.key, "WALLPAPER_MODE")) continue;
            writer.writePair(entry.key, entry.value);
        }
    }
    writer.writePair("DESKTOP_BG", color);
    writer.writePair("DESKTOP_ICON_TEXT", icon_text);
    writer.writePair("WALLPAPER", wallpaper);
    writer.writePair("WALLPAPER_MODE", "CENTER");
    if (!writer.ok()) return r4std.config.error_buffer_too_small;
    return r4std.config.saveDocument(ctx, path, writer.bytes());
}

fn paletteIndex(color: u32) ?usize {
    for (model.palette, 0..) |candidate, index| {
        if (candidate == color) return index;
    }
    return null;
}

fn clampI32(value: i32, min: i32, max: i32) i32 {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

fn setZ(out: []u8, value: []const u8) void {
    @memset(out, 0);
    if (out.len == 0) return;
    const count = @min(value.len, out.len - 1);
    if (count > 0) @memcpy(out[0..count], value[0..count]);
    out[count] = 0;
}

fn copyZ(out: []u8, value: []const u8) []const u8 {
    setZ(out, value);
    return spanZ(out);
}

fn copyLit(out: []u8, comptime value: []const u8) []const u8 {
    if (out.len == 0) return out[0..0];
    @memset(out, 0);
    const count = @min(value.len, out.len - 1);
    inline for (value, 0..) |ch, index| {
        if (index < count) out[index] = ch;
    }
    out[count] = 0;
    return out[0..count];
}

fn spanZ(buffer: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0) : (len += 1) {}
    return buffer[0..len];
}

fn zptr(buffer: []const u8) [*:0]const u8 {
    return @ptrCast(buffer.ptr);
}

fn lastPathSeparator(path: []const u8) ?usize {
    var index = path.len;
    while (index > 0) {
        index -= 1;
        if (path[index] == '\\' or path[index] == '/') return index;
    }
    return null;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        var match: usize = 0;
        while (match < needle.len and haystack[index + match] == needle[match]) : (match += 1) {}
        if (match == needle.len) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (upper(left) != upper(right)) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}
