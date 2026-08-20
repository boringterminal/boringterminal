//! Small Objective-C runtime wrappers used by the macOS backend.

const std = @import("std");

pub const Id = ?*opaque {};
pub const Class = ?*opaque {};
pub const Sel = ?*opaque {};
pub const Ivar = ?*opaque {};

pub const CGFloat = f64;
pub const NSInteger = i64;
pub const NSUInteger = u64;
pub const BOOL = u8;
pub const NSNotFound: NSUInteger = std.math.maxInt(NSUInteger);

/// `NSStringEncoding` for UTF-8.
pub const NSUTF8StringEncoding: NSUInteger = 4;

pub const CGPoint = extern struct { x: CGFloat, y: CGFloat };
pub const CGSize = extern struct { width: CGFloat, height: CGFloat };
pub const CGRect = extern struct { origin: CGPoint, size: CGSize };
pub const NSRange = extern struct { location: NSUInteger, length: NSUInteger };

extern "c" fn objc_getClass(name: [*:0]const u8) Class;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
extern "c" fn objc_msgSend() void;

extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra: usize) Class;
extern "c" fn objc_registerClassPair(class: Class) void;
extern "c" fn class_addMethod(
    class: Class,
    sel_name: Sel,
    imp: *const anyopaque,
    types: [*:0]const u8,
) BOOL;
extern "c" fn class_addIvar(
    class: Class,
    name: [*:0]const u8,
    size: usize,
    alignment: u8,
    types: [*:0]const u8,
) BOOL;
extern "c" fn class_getInstanceVariable(class: Class, name: [*:0]const u8) Ivar;
extern "c" fn object_getIvar(obj: Id, ivar: Ivar) Id;
extern "c" fn object_setIvar(obj: Id, ivar: Ivar, value: Id) void;
extern "c" fn object_setClass(obj: Id, class: Class) Class;

pub fn cls(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

pub fn sel(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}

/// Cast `objc_msgSend` to the exact method signature before calling it.
pub fn msg(comptime Signature: type) Signature {
    return @ptrCast(&objc_msgSend);
}

pub fn nsString(cstr: [*:0]const u8) Id {
    const NSString = cls("NSString");
    return msg(*const fn (Class, Sel, [*:0]const u8) callconv(.c) Id)(
        NSString,
        sel("stringWithUTF8String:"),
        cstr,
    );
}

/// Allocate a runtime-defined Obj-C class.
pub fn allocateClass(superclass: Class, name: [*:0]const u8) Class {
    return objc_allocateClassPair(superclass, name, 0);
}

pub fn registerClass(class: Class) void {
    objc_registerClassPair(class);
}

/// Reclass an Objective-C object to a layout-compatible runtime subclass.
/// Runtime-built controls use this to retain an AppKit cell's configured
/// state while overriding drawing geometry without private ivar access.
pub fn setClass(obj: Id, class: Class) void {
    _ = object_setClass(obj, class);
}

/// `types` is the Objective-C method type encoding.
pub fn addMethod(class: Class, sel_name: Sel, imp: *const anyopaque, types: [*:0]const u8) void {
    _ = class_addMethod(class, sel_name, imp, types);
}

pub fn allocInit(class: Class) Id {
    const allocated = msg(*const fn (Class, Sel) callconv(.c) Id)(class, sel("alloc"));
    return msg(*const fn (Id, Sel) callconv(.c) Id)(allocated, sel("init"));
}

pub fn release(obj: Id) void {
    msg(*const fn (Id, Sel) callconv(.c) void)(obj, sel("release"));
}

pub fn retain(obj: Id) Id {
    return msg(*const fn (Id, Sel) callconv(.c) Id)(obj, sel("retain"));
}

/// Call a void setter that takes an integer-like argument.
pub fn setU(obj: Id, setter: Sel, value: NSUInteger) void {
    msg(*const fn (Id, Sel, NSUInteger) callconv(.c) void)(obj, setter, value);
}

/// Call a void setter that takes an Obj-C object.
pub fn setId(obj: Id, setter: Sel, value: Id) void {
    msg(*const fn (Id, Sel, Id) callconv(.c) void)(obj, setter, value);
}

/// Add a raw pointer ivar to a runtime-defined class.
pub fn addPointerIvar(class: Class, name: [*:0]const u8) void {
    _ = class_addIvar(
        class,
        name,
        @sizeOf(usize),
        @alignOf(usize),
        "^v",
    );
}

fn ivarOn(obj: Id, name: [*:0]const u8) Ivar {
    const class = msg(*const fn (Id, Sel) callconv(.c) Class)(obj, sel("class"));
    return class_getInstanceVariable(class, name);
}

pub fn setPointerIvar(obj: Id, name: [*:0]const u8, value: ?*anyopaque) void {
    object_setIvar(obj, ivarOn(obj, name), @ptrCast(value));
}

pub fn getPointerIvar(obj: Id, name: [*:0]const u8) ?*anyopaque {
    return @ptrCast(object_getIvar(obj, ivarOn(obj, name)));
}

// -- Boring Terminal additions ---------------------------------------------

pub const Protocol = ?*opaque {};

extern "c" fn objc_getProtocol(name: [*:0]const u8) Protocol;
extern "c" fn class_addProtocol(class: Class, protocol: Protocol) BOOL;

/// Declare conformance of a runtime-built class to a protocol so the text
/// input system recognizes it (NSTextInputClient).
pub fn addProtocol(class: Class, name: [*:0]const u8) void {
    const proto = objc_getProtocol(name);
    if (proto != null) _ = class_addProtocol(class, proto);
}

pub fn nsStringFromBytes(bytes: []const u8) Id {
    const alloced = msg(*const fn (Class, Sel) callconv(.c) Id)(cls("NSString"), sel("alloc"));
    return msg(*const fn (Id, Sel, [*]const u8, NSUInteger, NSUInteger) callconv(.c) Id)(
        alloced,
        sel("initWithBytes:length:encoding:"),
        bytes.ptr,
        bytes.len,
        NSUTF8StringEncoding,
    );
}

/// objc_msgSendSuper support for runtime-built subclasses that must call
/// their superclass implementation (NSView live-resize hooks).
pub const Super = extern struct {
    receiver: Id,
    super_class: Class,
};

extern "c" fn objc_msgSendSuper() void;

pub fn msgSuper(comptime Signature: type) Signature {
    return @ptrCast(&objc_msgSendSuper);
}
