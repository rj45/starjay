// USB HID Keyboard scan codes as per USB spec 1.11
// plus some additional codes
//
// Originally created by MightyPork, 2016 (Public domain)
// Adapted from:
// https://source.android.com/devices/input/keyboard-devices.html
//
// Converted to Zig enums with ASCII translation tables.

const std = @import("std");

pub const keyboard = @This();

pub const KEYBOARD_REG_ADDR: usize = 0x1000_0100;

pub const device: * volatile Report = @ptrFromInt(KEYBOARD_REG_ADDR);

/// Modifier key bitmask (first byte of HID report).
pub const Modifiers = packed struct(u8) {
    left_ctrl: bool = false,
    left_shift: bool = false,
    left_alt: bool = false,
    left_gui: bool = false,
    right_ctrl: bool = false,
    right_shift: bool = false,
    right_alt: bool = false,
    right_gui: bool = false,

    pub fn shift(self: Modifiers) bool {
        return self.left_shift or self.right_shift;
    }

    pub fn ctrl(self: Modifiers) bool {
        return self.left_ctrl or self.right_ctrl;
    }

    pub fn alt(self: Modifiers) bool {
        return self.left_alt or self.right_alt;
    }

    pub fn gui(self: Modifiers) bool {
        return self.left_gui or self.right_gui;
    }
};

/// USB HID keyboard report (8 bytes, suitable for MMIO register).
pub const Report = packed struct {
    modifiers: Modifiers,
    reserved: u8 = 0,
    key0: ScanCode = .none,
    key1: ScanCode = .none,
    key2: ScanCode = .none,
    key3: ScanCode = .none,
    key4: ScanCode = .none,
    key5: ScanCode = .none,

    /// Returns true if the given scan code is currently pressed.
    pub fn isPressed(self: *const Report, code: ScanCode) bool {
        if (self.key0 == code) return true;
        if (self.key1 == code) return true;
        if (self.key2 == code) return true;
        if (self.key3 == code) return true;
        if (self.key4 == code) return true;
        if (self.key5 == code) return true;
        return false;
    }

    /// Returns true if the report indicates rollover error (too many keys).
    pub fn isRolloverError(self: *const Report) bool {
        return self.keys[0] == .err_ovf;
    }

    /// Iterator over pressed (non-none) keys.
    pub fn pressedKeys(self: *volatile Report) PressedKeyIterator {
        return .{ .keys = .{self.key0, self.key1, self.key2, self.key3, self.key4, self.key5}, .index = 0 };
    }

    pub const PressedKeyIterator = struct {
        keys: [6]ScanCode,
        index: u3,

        pub fn next(self: *PressedKeyIterator) ?ScanCode {
            while (self.index < 6) {
                const k = self.keys[self.index];
                self.index += 1;
                if (k != .none) return k;
            }
            return null;
        }
    };
};

/// USB HID scan codes.
pub const ScanCode = enum(u8) {
    none = 0x00,
    err_ovf = 0x01, // Rollover error

    a = 0x04,
    b = 0x05,
    c = 0x06,
    d = 0x07,
    e = 0x08,
    f = 0x09,
    g = 0x0a,
    h = 0x0b,
    i = 0x0c,
    j = 0x0d,
    k = 0x0e,
    l = 0x0f,
    m = 0x10,
    n = 0x11,
    o = 0x12,
    p = 0x13,
    q = 0x14,
    r = 0x15,
    s = 0x16,
    t = 0x17,
    u = 0x18,
    v = 0x19,
    w = 0x1a,
    x = 0x1b,
    y = 0x1c,
    z = 0x1d,

    @"1" = 0x1e,
    @"2" = 0x1f,
    @"3" = 0x20,
    @"4" = 0x21,
    @"5" = 0x22,
    @"6" = 0x23,
    @"7" = 0x24,
    @"8" = 0x25,
    @"9" = 0x26,
    @"0" = 0x27,

    enter = 0x28,
    esc = 0x29,
    backspace = 0x2a,
    tab = 0x2b,
    space = 0x2c,
    minus = 0x2d,
    equal = 0x2e,
    left_brace = 0x2f,
    right_brace = 0x30,
    backslash = 0x31,
    hash_tilde = 0x32,
    semicolon = 0x33,
    apostrophe = 0x34,
    grave = 0x35,
    comma = 0x36,
    dot = 0x37,
    slash = 0x38,
    caps_lock = 0x39,

    f1 = 0x3a,
    f2 = 0x3b,
    f3 = 0x3c,
    f4 = 0x3d,
    f5 = 0x3e,
    f6 = 0x3f,
    f7 = 0x40,
    f8 = 0x41,
    f9 = 0x42,
    f10 = 0x43,
    f11 = 0x44,
    f12 = 0x45,

    sysrq = 0x46,
    scroll_lock = 0x47,
    pause = 0x48,
    insert = 0x49,
    home = 0x4a,
    page_up = 0x4b,
    delete = 0x4c,
    end = 0x4d,
    page_down = 0x4e,
    right = 0x4f,
    left = 0x50,
    down = 0x51,
    up = 0x52,

    num_lock = 0x53,
    kp_slash = 0x54,
    kp_asterisk = 0x55,
    kp_minus = 0x56,
    kp_plus = 0x57,
    kp_enter = 0x58,
    kp_1 = 0x59,
    kp_2 = 0x5a,
    kp_3 = 0x5b,
    kp_4 = 0x5c,
    kp_5 = 0x5d,
    kp_6 = 0x5e,
    kp_7 = 0x5f,
    kp_8 = 0x60,
    kp_9 = 0x61,
    kp_0 = 0x62,
    kp_dot = 0x63,

    @"102nd" = 0x64,
    compose = 0x65,
    power = 0x66,
    kp_equal = 0x67,

    f13 = 0x68,
    f14 = 0x69,
    f15 = 0x6a,
    f16 = 0x6b,
    f17 = 0x6c,
    f18 = 0x6d,
    f19 = 0x6e,
    f20 = 0x6f,
    f21 = 0x70,
    f22 = 0x71,
    f23 = 0x72,
    f24 = 0x73,

    open = 0x74,
    help = 0x75,
    props = 0x76,
    front = 0x77,
    stop = 0x78,
    again = 0x79,
    undo = 0x7a,
    cut = 0x7b,
    copy = 0x7c,
    paste = 0x7d,
    find = 0x7e,
    mute = 0x7f,
    volume_up = 0x80,
    volume_down = 0x81,

    kp_comma = 0x85,

    intl1 = 0x87,
    intl2 = 0x88,
    intl3 = 0x89,
    intl4 = 0x8a,
    intl5 = 0x8b,
    intl6 = 0x8c,
    intl7 = 0x8d,
    intl8 = 0x8e,
    intl9 = 0x8f,

    lang1 = 0x90,
    lang2 = 0x91,
    lang3 = 0x92,
    lang4 = 0x93,
    lang5 = 0x94,
    lang6 = 0x95,
    lang7 = 0x96,
    lang8 = 0x97,
    lang9 = 0x98,

    kp_left_paren = 0xb6,
    kp_right_paren = 0xb7,

    left_ctrl = 0xe0,
    left_shift = 0xe1,
    left_alt = 0xe2,
    left_meta = 0xe3,
    right_ctrl = 0xe4,
    right_shift = 0xe5,
    right_alt = 0xe6,
    right_meta = 0xe7,

    media_play_pause = 0xe8,
    media_stop_cd = 0xe9,
    media_prev_song = 0xea,
    media_next_song = 0xeb,
    media_eject_cd = 0xec,
    media_volume_up = 0xed,
    media_volume_down = 0xee,
    media_mute = 0xef,
    media_www = 0xf0,
    media_back = 0xf1,
    media_forward = 0xf2,
    media_stop = 0xf3,
    media_find = 0xf4,
    media_scroll_up = 0xf5,
    media_scroll_down = 0xf6,
    media_edit = 0xf7,
    media_sleep = 0xf8,
    media_coffee = 0xf9,
    media_refresh = 0xfa,
    media_calc = 0xfb,

    _,

    // ----- ASCII translation tables (US layout) -----

    // Unshifted ASCII for scan codes 0x04..0x38
    // Index: scan_code - 0x04
    const ascii_unshifted = [_]u8{
        'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', // 0x04-0x0b
        'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', // 0x0c-0x13
        'q', 'r', 's', 't', 'u', 'v', 'w', 'x', // 0x14-0x1b
        'y', 'z', // 0x1c-0x1d
        '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', // 0x1e-0x27
        '\r', 0x1b, 0x08, '\t', ' ', // enter, esc, bs, tab, space
        '-', '=', '[', ']', '\\', // 0x2d-0x31
        '#', // 0x32 hash_tilde (non-US)
        ';', '\'', '`', ',', '.', '/', // 0x33-0x38
    };

    // Shifted ASCII for the same range
    const ascii_shifted = [_]u8{
        'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', // 0x04-0x0b
        'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', // 0x0c-0x13
        'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', // 0x14-0x1b
        'Y', 'Z', // 0x1c-0x1d
        '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', // 0x1e-0x27
        '\r', 0x1b, 0x08, '\t', ' ', // enter, esc, bs, tab, space
        '_', '+', '{', '}', '|', // 0x2d-0x31
        '~', // 0x32 hash_tilde shifted
        ':', '"', '~', '<', '>', '?', // 0x33-0x38
    };

    // Keypad digit ASCII (scan codes 0x54..0x63)
    // Index: scan_code - 0x54
    const kp_ascii = [_]u8{
        '/', '*', '-', '+', '\r', // slash, asterisk, minus, plus, enter
        '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '.', // kp_1..kp_dot
    };

    /// Convert this scan code to an ASCII character given the current modifiers.
    /// Returns null if the scan code has no ASCII representation.
    pub fn toAscii(self: ScanCode, mods: Modifiers) ?u8 {
        const code = @intFromEnum(self);

        // Main printable range: 0x04 (a) .. 0x38 (slash)
        if (code >= 0x04 and code <= 0x38) {
            const idx = code - 0x04;
            const ch = if (mods.shift()) ascii_shifted[idx] else ascii_unshifted[idx];

            // Ctrl+letter produces control codes 0x01..0x1a
            if (mods.ctrl() and ch >= 'a' and ch <= 'z')
                return ch - 'a' + 1;
            if (mods.ctrl() and ch >= 'A' and ch <= 'Z')
                return ch - 'A' + 1;

            return ch;
        }

        // Delete key
        if (code == 0x4c) return 0x7f;

        // Keypad range: 0x54 (kp_slash) .. 0x63 (kp_dot)
        if (code >= 0x54 and code <= 0x63) {
            return kp_ascii[code - 0x54];
        }

        return null;
    }

    /// Returns true if this scan code corresponds to a printable ASCII character
    /// (i.e. toAscii would return a value >= 0x20).
    pub fn isPrintable(self: ScanCode, mods: Modifiers) bool {
        const ch = self.toAscii(mods) orelse return false;
        return ch >= 0x20 and ch < 0x7f;
    }
};

// Compile-time sanity checks on table sizes.
comptime {
    // 0x04..0x38 inclusive = 0x35 = 53 entries
    std.debug.assert(ScanCode.ascii_unshifted.len == 0x38 - 0x04 + 1);
    std.debug.assert(ScanCode.ascii_shifted.len == 0x38 - 0x04 + 1);
    // 0x54..0x63 inclusive = 16 entries
    std.debug.assert(ScanCode.kp_ascii.len == 0x63 - 0x54 + 1);
}
