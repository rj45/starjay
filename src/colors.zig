const dvui = @import("dvui");

const Color = dvui.Color;

pub const colors = struct {
    // Background Colors
    pub const bg_void = Color.fromHex("#0a0a14"); // Main window background
    pub const bg_panel = Color.fromHex("#1a1a2e"); // Panel backgrounds
    pub const bg_surface = Color.fromHex("#252540"); // Raised elements
    pub const bg_active = Color.fromHex("#3d2e1a"); // Current line highlight
    pub const bg_hover = Color.fromHex("#2a2a44"); // Hover states

    // Text Colors
    pub const text_primary = Color.fromHex("#e8e6e3"); // Main text
    pub const text_secondary = Color.fromHex("#8a8a9a"); // Secondary info
    pub const text_muted = Color.fromHex("#5a5a6a"); // Disabled text
    pub const text_bright = Color.fromHex("#ffffff"); // Emphasized text

    // Semantic Colors (Colorblind-Safe)
    pub const state_read = Color.fromHex("#4ec9b0"); // Cyan/teal - read
    pub const state_write = Color.fromHex("#daa520"); // Amber/gold - write
    pub const state_change = Color.fromHex("#c678dd"); // Magenta/violet - changed
    pub const state_removed = Color.fromHex("#5a4a4a"); // Faded brown - removed
    pub const state_current = Color.fromHex("#ffd700"); // Bright gold - current
    pub const state_error = Color.fromHex("#e06c60"); // Coral/orange - errors
    pub const state_success = Color.fromHex("#4ec9b0"); // Cyan/teal - success

    // Syntax Highlighting Colors
    pub const syntax_instruction = Color.fromHex("#56b6c2"); // Bright cyan
    pub const syntax_register = Color.fromHex("#e06c75"); // Soft coral-pink
    pub const syntax_number = Color.fromHex("#d19a66"); // Warm gold
    pub const syntax_label = Color.fromHex("#b4a7d6"); // Soft lavender
    pub const syntax_comment = Color.fromHex("#5c6370"); // Blue-gray
    pub const syntax_directive = Color.fromHex("#61afef"); // Sky blue
    pub const syntax_string = Color.fromHex("#98c379"); // Sage green

    // UI Element Colors
    pub const border_default = Color.fromHex("#3a3a5a"); // Default borders
    pub const border_focus = Color.fromHex("#4ec9b0"); // Focused border
    pub const border_active = Color.fromHex("#ffd700"); // Active border
    pub const button_primary = Color.fromHex("#2e8b8b"); // Primary buttons
    pub const button_hover = Color.fromHex("#3aa8a8"); // Button hover
    pub const scrollbar = Color.fromHex("#3a3a5a"); // Scrollbar
};
