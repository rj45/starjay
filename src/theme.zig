const dvui = @import("dvui");
const colors = @import("colors.zig").colors;

const Color = dvui.Color;
const Font = dvui.Font;
const Theme = dvui.Theme;
const Options = dvui.Options;

const accent = colors.bg_active;
const accent_hsl = Color.HSLuv.fromColor(accent);
const err = Color{ .r = 0xe0, .g = 0x1b, .b = 0x24 };
const err_hsl = Color.HSLuv.fromColor(err);

// need to have these as separate variables because inlining them below trips
// zig's comptime eval quota
const dark_fill = colors.bg_panel;
const dark_fill_hsl = Color.HSLuv.fromColor(dark_fill);
const dark_err = Color{ .r = 0xc0, .g = 0x1c, .b = 0x28 };
const dark_err_hsl = Color.HSLuv.fromColor(dark_err);

const dark_accent_accent = accent_hsl.lighten(12).color();
const dark_accent_fill_hover = accent_hsl.lighten(9).color();
const dark_accent_border = accent_hsl.lighten(17).color();

const dark_err_accent = dark_err_hsl.lighten(14).color();
const dark_err_fill_hover = err_hsl.lighten(9).color();
const dark_err_fill_press = err_hsl.lighten(16).color();
const dark_err_border = err_hsl.lighten(20).color();

const light_accent_accent = accent_hsl.lighten(-16).color();
const light_accent_fill = accent_hsl.color();
const light_accent_fill_hover = accent_hsl.lighten(-11).color();
const light_accent_border = accent_hsl.lighten(-22).color();

const light_err_accent = err_hsl.lighten(-15).color();
const light_err_fill = err_hsl.color();
const light_err_fill_hover = err_hsl.lighten(-10).color();
const light_err_border = err_hsl.lighten(-20).color();

pub const dark = dark: {
    @setEvalBranchQuota(3023);
    break :dark Theme{
        .name = "Retro Dark",
        .dark = true,

        .font_body = .{ .size = 16, .id = .Vera },
        .font_heading = .{ .size = 16, .id = .VeraBd },
        .font_caption = .{ .size = 13, .id = .Vera, .line_height_factor = 1.1 },
        .font_caption_heading = .{ .size = 13, .id = .VeraBd, .line_height_factor = 1.1 },
        .font_title = .{ .size = 28, .id = .Vera },
        .font_title_1 = .{ .size = 24, .id = .VeraBd },
        .font_title_2 = .{ .size = 22, .id = .VeraBd },
        .font_title_3 = .{ .size = 20, .id = .VeraBd },
        .font_title_4 = .{ .size = 18, .id = .VeraBd },

        .focus = accent,

        .fill = colors.bg_void,
        .fill_hover = dark_fill_hsl.lighten(21).color(),
        .fill_press = dark_fill_hsl.lighten(30).color(),
        .text = colors.text_primary,
        .text_select = colors.text_bright,
        .border = colors.border_default,

        .control = .{
            .fill = dark_fill_hsl.lighten(5).color(),
            .fill_hover = dark_fill_hsl.lighten(21).color(),
            .fill_press = dark_fill_hsl.lighten(30).color(),
        },

        .window = .{
            .fill = dark_fill,
        },

        .highlight = .{
            .fill = accent,
            .fill_hover = dark_accent_fill_hover,
            .fill_press = dark_accent_accent,
            .text = colors.text_bright,
            .border = dark_accent_border,
        },

        .err = .{
            .fill = dark_err,
            .fill_hover = dark_err_fill_hover,
            .fill_press = dark_err_fill_press,
            .text = colors.text_bright,
            .border = dark_err_border,
        },
    };
};

pub const light = light: {
    @setEvalBranchQuota(3123);
    break :light Theme{
        .name = "Retro Light",
        .dark = false,

        .font_body = .{ .size = 16, .id = .Vera },
        .font_heading = .{ .size = 16, .id = .VeraBd },
        .font_caption = .{ .size = 13, .id = .Vera, .line_height_factor = 1.1 },
        .font_caption_heading = .{ .size = 13, .id = .VeraBd, .line_height_factor = 1.1 },
        .font_title = .{ .size = 28, .id = .Vera },
        .font_title_1 = .{ .size = 24, .id = .VeraBd },
        .font_title_2 = .{ .size = 22, .id = .VeraBd },
        .font_title_3 = .{ .size = 20, .id = .VeraBd },
        .font_title_4 = .{ .size = 18, .id = .VeraBd },

        .focus = accent,

        .fill = Color.white,
        .fill_hover = (Color.HSLuv{ .s = 0, .l = 82 }).color(),
        .fill_press = (Color.HSLuv{ .s = 0, .l = 72 }).color(),
        .text = Color.black,
        .text_select = .{ .r = 0x91, .g = 0xbc, .b = 0xf0 },
        .border = (Color.HSLuv{ .s = 0, .l = 63 }).color(),

        .control = .{
            .fill = .{ .r = 0xe0, .g = 0xe0, .b = 0xe0 },
            .fill_hover = (Color.HSLuv{ .s = 0, .l = 82 }).color(),
            .fill_press = (Color.HSLuv{ .s = 0, .l = 72 }).color(),
        },

        .window = .{
            .fill = .{ .r = 0xf0, .g = 0xf0, .b = 0xf0 },
        },

        .highlight = .{
            .fill = light_accent_fill,
            .fill_hover = light_accent_fill_hover,
            .fill_press = light_accent_accent,
            .text = Color.white,
            .border = light_accent_border,
        },

        .err = .{
            .fill = light_err_fill,
            .fill_hover = light_err_fill_hover,
            .fill_press = light_err_accent,
            .text = Color.white,
            .border = light_err_border,
        },
    };
};
