//! Pure opening policy for untrusted OSC 8 URIs (RFC 0018).

const std = @import("std");
const vt = @import("../vt.zig");

pub const Decision = enum { direct, confirm, reject };

pub fn classify(bytes: []const u8, local_hostname: []const u8) Decision {
    if (bytes.len == 0 or bytes.len > vt.hyperlink.max_uri_bytes or
        !vt.hyperlink.validPrintableAscii(bytes) or !validPercentEscapes(bytes)) return .reject;
    const uri = std.Uri.parse(bytes) catch return .reject;

    if (std.ascii.eqlIgnoreCase(uri.scheme, "file"))
        return classifyFile(uri, local_hostname);
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        std.ascii.eqlIgnoreCase(uri.scheme, "https") or
        std.ascii.eqlIgnoreCase(uri.scheme, "ftp"))
    {
        const host = uri.host orelse return .reject;
        if (host.isEmpty()) return .reject;
        return .direct;
    }
    if (std.ascii.eqlIgnoreCase(uri.scheme, "mailto"))
        return if (uri.path.isEmpty()) .reject else .direct;
    return .confirm;
}

fn validPercentEscapes(bytes: []const u8) bool {
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] != '%') continue;
        if (index + 2 >= bytes.len or
            !std.ascii.isHex(bytes[index + 1]) or
            !std.ascii.isHex(bytes[index + 2])) return false;
        index += 2;
    }
    return true;
}

fn classifyFile(uri: std.Uri, local_hostname: []const u8) Decision {
    if (uri.user != null or uri.password != null or uri.port != null or
        uri.query != null or uri.fragment != null) return .reject;

    if (uri.host) |component| {
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = component.toRaw(&host_buf) catch return .reject;
        if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost") and
            !std.ascii.eqlIgnoreCase(host, local_hostname)) return .reject;
    }

    var path_buf: [vt.hyperlink.max_uri_bytes]u8 = undefined;
    const path = uri.path.toRaw(&path_buf) catch return .reject;
    if (path.len == 0 or path[0] != '/') return .reject;
    for (path) |byte| if (byte == 0 or byte < 0x20 or byte == 0x7f) return .reject;
    return .direct;
}

test "known absolute hyperlink schemes open directly" {
    try std.testing.expectEqual(Decision.direct, classify("https://example.com/a", "mac"));
    try std.testing.expectEqual(Decision.direct, classify("HTTP://example.com", "mac"));
    try std.testing.expectEqual(Decision.direct, classify("mailto:user@example.com", "mac"));
    try std.testing.expectEqual(Decision.confirm, classify("zed://file/project/main.zig", "mac"));
}

test "web and mail links require their meaningful component" {
    try std.testing.expectEqual(Decision.reject, classify("https:///path", "mac"));
    try std.testing.expectEqual(Decision.reject, classify("mailto:", "mac"));
    try std.testing.expectEqual(Decision.reject, classify("relative/path", "mac"));
}

test "file links are local absolute paths only" {
    try std.testing.expectEqual(Decision.direct, classify("file:///tmp/a", "my-mac"));
    try std.testing.expectEqual(Decision.direct, classify("file://localhost/tmp/a", "my-mac"));
    try std.testing.expectEqual(Decision.direct, classify("file://my-mac/tmp/a", "my-mac"));
    try std.testing.expectEqual(Decision.reject, classify("file://remote/tmp/a", "my-mac"));
    try std.testing.expectEqual(Decision.reject, classify("file:relative", "my-mac"));
    try std.testing.expectEqual(Decision.reject, classify("file:///tmp/a%0Aevil", "my-mac"));
}

test "control bytes and malformed escapes are rejected" {
    try std.testing.expectEqual(Decision.reject, classify("https://example.com/\n", "mac"));
    try std.testing.expectEqual(Decision.reject, classify("https://example.com/%", "mac"));
}
