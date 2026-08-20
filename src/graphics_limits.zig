//! Shared decoded-image resource limits. The daemon store and private attach
//! codec must reject the same shapes and totals.

pub const max_images: usize = 64;
pub const max_image_bytes: usize = 64 * 1024 * 1024;
pub const max_total_bytes: usize = 128 * 1024 * 1024;
