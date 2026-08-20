//! CoreText + CoreGraphics externs. No wrappers live here beyond what the
//! C/Obj-C signatures require; each call site owns its retain/release
//! pairing.

const objc = @import("objc.zig");

pub const CGFloat = f64;
pub const CFIndex = i64;
pub const CGGlyph = u16;

pub const CGPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const CGSize = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
pub const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };
pub const CGAffineTransform = extern struct {
    a: CGFloat = 1,
    b: CGFloat = 0,
    c: CGFloat = 0,
    d: CGFloat = 1,
    tx: CGFloat = 0,
    ty: CGFloat = 0,
};

pub const CFRange = extern struct { location: CFIndex = 0, length: CFIndex = 0 };

pub const CTFontOrientation = enum(u32) {
    default = 0,
    horizontal = 1,
    vertical = 2,
};

/// CTFontUIFontType. Only the values zig-ui uses.
pub const CTFontUIFontType = enum(i32) {
    system = 2,
    user = 4,
    user_fixed_pitch = 5,
};

/// CGImageAlphaInfo bits used in `CGBitmapContextCreate.bitmapInfo`.
pub const AlphaInfo = struct {
    pub const none: u32 = 0;
    pub const premultiplied_last: u32 = 1;
    pub const alpha_only: u32 = 7;
};

// CoreText

pub extern "c" fn CTFontCreateUIFontForLanguage(
    ui_type: CTFontUIFontType,
    size: CGFloat,
    language: objc.Id,
) objc.Id;

pub extern "c" fn CTFontGetAscent(font: objc.Id) CGFloat;
pub extern "c" fn CTFontGetDescent(font: objc.Id) CGFloat;
pub extern "c" fn CTFontGetLeading(font: objc.Id) CGFloat;
pub extern "c" fn CTFontGetSize(font: objc.Id) CGFloat;
pub extern "c" fn CTFontGetSymbolicTraits(font: objc.Id) u32;
pub extern "c" fn CTFontCreateCopyWithSymbolicTraits(
    font: objc.Id,
    size: CGFloat,
    matrix: ?*const CGAffineTransform,
    symbolic_value: u32,
    symbolic_mask: u32,
) objc.Id;

pub const FontTrait = struct {
    pub const italic: u32 = 1 << 0;
    pub const bold: u32 = 1 << 1;
    pub const monospace: u32 = 1 << 10;
    pub const color_glyphs: u32 = 1 << 13;
};

/// Fill `glyphs[0..count]` with the glyph IDs that map to the given UTF-16
/// code points. No shaping, no kerning; `shapeLine` below is the path for
/// production text.
pub extern "c" fn CTFontGetGlyphsForCharacters(
    font: objc.Id,
    characters: [*]const u16,
    glyphs: [*]CGGlyph,
    count: CFIndex,
) bool;

/// Returns the union bounding rect and writes per-glyph rects into
/// `bounding_rects`.
pub extern "c" fn CTFontGetBoundingRectsForGlyphs(
    font: objc.Id,
    orientation: CTFontOrientation,
    glyphs: [*]const CGGlyph,
    bounding_rects: ?[*]CGRect,
    count: CFIndex,
) CGRect;

/// Returns the total advance and writes per-glyph advances into `advances`.
pub extern "c" fn CTFontGetAdvancesForGlyphs(
    font: objc.Id,
    orientation: CTFontOrientation,
    glyphs: [*]const CGGlyph,
    advances: ?[*]CGSize,
    count: CFIndex,
) f64;

pub extern "c" fn CTFontDrawGlyphs(
    font: objc.Id,
    glyphs: [*]const CGGlyph,
    positions: [*]const CGPoint,
    count: usize,
    context: objc.Id,
) void;

// CoreGraphics

pub extern "c" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bits_per_component: usize,
    bytes_per_row: usize,
    color_space: objc.Id,
    bitmap_info: u32,
) objc.Id;

pub extern "c" fn CGColorSpaceCreateDeviceGray() objc.Id;
pub extern "c" fn CGColorSpaceCreateDeviceRGB() objc.Id;
pub extern "c" fn CGColorSpaceRelease(cs: objc.Id) void;

pub extern "c" fn CGContextRelease(ctx: objc.Id) void;

pub extern "c" fn CGContextTranslateCTM(ctx: objc.Id, tx: CGFloat, ty: CGFloat) void;
pub extern "c" fn CGContextScaleCTM(ctx: objc.Id, sx: CGFloat, sy: CGFloat) void;
pub extern "c" fn CGContextSetShouldAntialias(ctx: objc.Id, flag: bool) void;
pub extern "c" fn CGContextSetAllowsFontSmoothing(ctx: objc.Id, flag: bool) void;
pub extern "c" fn CGContextSetShouldSmoothFonts(ctx: objc.Id, flag: bool) void;
pub extern "c" fn CGContextSetGrayFillColor(ctx: objc.Id, gray: CGFloat, alpha: CGFloat) void;
pub extern "c" fn CGContextSetGrayStrokeColor(ctx: objc.Id, gray: CGFloat, alpha: CGFloat) void;
pub extern "c" fn CGContextSetRGBFillColor(
    ctx: objc.Id,
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat,
    alpha: CGFloat,
) void;
pub extern "c" fn CGContextSetLineWidth(ctx: objc.Id, width: CGFloat) void;
pub const CGTextDrawingMode = enum(i32) {
    fill_stroke = 2,
};
pub extern "c" fn CGContextSetTextDrawingMode(ctx: objc.Id, mode: CGTextDrawingMode) void;
pub extern "c" fn CGContextSetTextPosition(ctx: objc.Id, x: CGFloat, y: CGFloat) void;
/// CGBitmapInfo bit values used when building an RGBA8 bitmap context.
/// `byte_order_32_big` + `premultiplied_last` lays bytes out as
/// `[R, G, B, A]` with straight alpha premultiplied by CoreGraphics during
/// the draw.
pub const BitmapInfo = struct {
    pub const byte_order_32_big: u32 = 4 << 12;
    pub const premultiplied_last: u32 = 1;
};

// CoreText shaping

/// Attributes key for the font applied to a range of an attributed string.
/// The value must be a CTFontRef (or NSFont, toll-free bridged). Externed
/// from CoreText.framework so NSMutableAttributedString.addAttribute sees
/// the exact interned constant CoreText compares against.
pub extern const kCTFontAttributeName: objc.Id;
pub extern const kCTKernAttributeName: objc.Id;
pub extern const kCTForegroundColorFromContextAttributeName: objc.Id;
pub extern const kCFBooleanTrue: objc.Id;
pub extern fn CFNumberCreate(allocator: ?*anyopaque, the_type: isize, value_ptr: *const anyopaque) objc.Id;
/// `kCFNumberFloat32Type`.
pub const cf_number_float32: isize = 12;

pub extern "c" fn CTLineCreateWithAttributedString(attr_string: objc.Id) objc.Id;
/// Returns an unretained CFArrayRef of CTRunRefs owned by the CTLine.
pub extern "c" fn CTLineGetGlyphRuns(line: objc.Id) objc.Id;
/// Returns the line's typographic width in points. Fills the out pointers
/// with per-font ascent/descent/leading if they are non-null.
pub extern "c" fn CTLineGetTypographicBounds(
    line: objc.Id,
    ascent: ?*CGFloat,
    descent: ?*CGFloat,
    leading: ?*CGFloat,
) f64;
pub extern "c" fn CTLineDraw(line: objc.Id, context: objc.Id) void;

pub extern "c" fn CFArrayGetCount(array: objc.Id) CFIndex;
pub extern "c" fn CFArrayGetValueAtIndex(array: objc.Id, idx: CFIndex) objc.Id;

pub extern "c" fn CTRunGetGlyphCount(run: objc.Id) CFIndex;
pub extern "c" fn CTRunGetAttributes(run: objc.Id) objc.Id;
pub extern "c" fn CTRunGetGlyphs(run: objc.Id, range: CFRange, buffer: [*]CGGlyph) void;
pub extern "c" fn CTRunGetPositions(run: objc.Id, range: CFRange, buffer: [*]CGPoint) void;
pub extern "c" fn CFDictionaryGetValue(dictionary: objc.Id, key: objc.Id) objc.Id;

// CoreText framesetter: wraps a paragraph of attributed text into a
// sequence of CTLines within a given column width.

pub extern "c" fn CTFramesetterCreateWithAttributedString(attr_string: objc.Id) objc.Id;
pub extern "c" fn CTFramesetterCreateFrame(
    framesetter: objc.Id,
    string_range: CFRange,
    path: objc.Id,
    frame_attributes: objc.Id,
) objc.Id;
pub extern "c" fn CTFramesetterSuggestFrameSizeWithConstraints(
    framesetter: objc.Id,
    string_range: CFRange,
    frame_attributes: objc.Id,
    constraints: CGSize,
    fit_range: ?*CFRange,
) CGSize;
/// Returns an unretained `CFArrayRef` of `CTLineRef` owned by the frame.
pub extern "c" fn CTFrameGetLines(frame: objc.Id) objc.Id;

// CoreGraphics path

pub extern "c" fn CGPathCreateWithRect(rect: CGRect, transform: ?*anyopaque) objc.Id;
pub extern "c" fn CGPathRelease(path: objc.Id) void;

// CoreFoundation

pub extern "c" fn CFRelease(cf: objc.Id) void;

// -- Boring Terminal additions ---------------------------------------------

/// Returns a font (following the system cascade) able to render `string`
/// within `range`. The workhorse of per-codepoint font fallback.
pub extern "c" fn CTFontCreateForString(
    current_font: objc.Id,
    string: objc.Id,
    range: CFRange,
) objc.Id;

pub extern "c" fn CFEqual(a: objc.Id, b: objc.Id) u8;
