//! Darwin local connections. A stale socket is an expected recovery condition,
//! including on Zig 0.16 whose Io Unix connect omits ECONNREFUSED.
const std = @import("std");
const c = std.c;

pub fn connect(path: []const u8) !c.fd_t {
    var address: c.sockaddr.un = .{ .path = @splat(0) };
    if (path.len == 0 or path.len >= address.path.len or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidSocketPath;
    @memcpy(address.path[0..path.len], path);
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.SocketFailed;
    while (true) {
        const rc = c.connect(fd, @ptrCast(&address), @sizeOf(c.sockaddr.un));
        if (rc == 0) return fd;
        switch (c.errno(rc)) {
            .INTR => continue,
            .ISCONN => return fd,
            .CONNREFUSED => return error.ConnectionRefused,
            .NOENT => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            else => return error.ConnectionFailed,
        }
    }
}
