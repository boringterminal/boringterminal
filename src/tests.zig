//! Test root: everything runs without a window. CoreText/AppKit font services
//! are linked for raster smoke tests; presentation is exercised through the
//! production Metal pipelines offscreen (RFC 0004/0013).

test {
    _ = @import("config.zig");
    _ = @import("vt.zig");
    _ = @import("shell/pty.zig");
    _ = @import("shell/input.zig");
    _ = @import("shell/key_normalizer.zig");
    _ = @import("shell/graphics.zig");
    _ = @import("shell/session.zig");
    _ = @import("shell/title.zig");
    _ = @import("shell/sidebar_layout.zig");
    _ = @import("shell/search_bar.zig");
    _ = @import("shell/hyperlink.zig");
    _ = @import("shell/path_drop.zig");
    _ = @import("shell/font_zoom.zig");
    _ = @import("shell/working_directory.zig");
    _ = @import("shell/display_model.zig");
    _ = @import("shell/config_watcher.zig");
    _ = @import("daemon/protocol.zig");
    _ = @import("daemon/display_registry.zig");
    _ = @import("daemon/integration_tests.zig");
    _ = @import("shell/daemon_client.zig");
    _ = @import("shell/daemon_protocol/compat/metadata_v10_v13.zig");
    _ = @import("render/box_drawing.zig");
    _ = @import("render/font.zig");
    _ = @import("render/atlas.zig");
    _ = @import("render/renderer.zig");
    _ = @import("render/graphics_transport.zig");
    _ = @import("render/staged_upload.zig");
}
