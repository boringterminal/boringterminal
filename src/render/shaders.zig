//! MSL sources, runtime-compiled (no build-time metal toolchain
//! dependency). Two pipelines: solid cell quads (backgrounds, cursor,
//! underline/strike decorations) and atlas-sampled glyph quads. Positions
//! are in points; the viewport uniform normalizes to NDC, so backing scale
//! never leaks into instance data.

pub const quad =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct QuadInstance {
    \\    packed_float2 origin;   // top-left, points
    \\    packed_float2 size;     // points
    \\    packed_float4 color;    // rgba, straight alpha
    \\};
    \\
    \\struct QuadOut {
    \\    float4 position [[position]];
    \\    float4 color;
    \\};
    \\
    \\constant float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
    \\
    \\vertex QuadOut quad_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    const device QuadInstance* instances [[buffer(0)]],
    \\    constant float2& viewport [[buffer(1)]]
    \\) {
    \\    QuadInstance inst = instances[iid];
    \\    float2 pos = inst.origin + corners[vid] * inst.size;
    \\    float2 ndc = (pos / viewport) * 2.0 - 1.0;
    \\    ndc.y = -ndc.y;
    \\    QuadOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.color = inst.color;
    \\    return out;
    \\}
    \\
    \\fragment float4 quad_fragment(QuadOut in [[stage_in]]) {
    \\    return in.color;
    \\}
;

pub const glyph =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct GlyphInstance {
    \\    packed_float2 origin;   // top-left of the glyph quad, points
    \\    packed_float2 size;     // points
    \\    packed_float4 uv;       // (u0, v0, u1, v1) atlas, normalized
    \\    packed_float4 color;    // rgba, straight alpha
    \\};
    \\
    \\struct GlyphOut {
    \\    float4 position [[position]];
    \\    float2 uv;
    \\    float4 color;
    \\};
    \\
    \\constant float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
    \\
    \\vertex GlyphOut glyph_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    const device GlyphInstance* instances [[buffer(0)]],
    \\    constant float2& viewport [[buffer(1)]]
    \\) {
    \\    GlyphInstance inst = instances[iid];
    \\    float2 corner = corners[vid];
    \\    float2 pos = inst.origin + corner * inst.size;
    \\    float2 ndc = (pos / viewport) * 2.0 - 1.0;
    \\    ndc.y = -ndc.y;
    \\    GlyphOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.uv = float2(mix(inst.uv.x, inst.uv.z, corner.x),
    \\                    mix(inst.uv.y, inst.uv.w, corner.y));
    \\    out.color = inst.color;
    \\    return out;
    \\}
    \\
    \\fragment float4 glyph_fragment(
    \\    GlyphOut in [[stage_in]],
    \\    texture2d<float> atlas [[texture(0)]]
    \\) {
    \\    constexpr sampler atlas_sampler(address::clamp_to_edge, filter::linear);
    \\    float mask = atlas.sample(atlas_sampler, in.uv).r;
    \\    return float4(in.color.rgb, in.color.a * mask);
    \\}
;

/// Color glyphs are stored as premultiplied RGBA. Their pipeline uses
/// source-one blending, so dimming must scale RGB and alpha together.
pub const color_glyph =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct GlyphInstance {
    \\    packed_float2 origin;
    \\    packed_float2 size;
    \\    packed_float4 uv;
    \\    packed_float4 color;    // alpha is glyph opacity; rgb unused
    \\};
    \\
    \\struct GlyphOut {
    \\    float4 position [[position]];
    \\    float2 uv;
    \\    float opacity;
    \\};
    \\
    \\constant float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
    \\
    \\vertex GlyphOut color_glyph_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    const device GlyphInstance* instances [[buffer(0)]],
    \\    constant float2& viewport [[buffer(1)]]
    \\) {
    \\    GlyphInstance inst = instances[iid];
    \\    float2 corner = corners[vid];
    \\    float2 pos = inst.origin + corner * inst.size;
    \\    float2 ndc = (pos / viewport) * 2.0 - 1.0;
    \\    ndc.y = -ndc.y;
    \\    GlyphOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.uv = float2(mix(inst.uv.x, inst.uv.z, corner.x),
    \\                    mix(inst.uv.y, inst.uv.w, corner.y));
    \\    out.opacity = inst.color.a;
    \\    return out;
    \\}
    \\
    \\fragment float4 color_glyph_fragment(
    \\    GlyphOut in [[stage_in]],
    \\    texture2d<float> atlas [[texture(0)]]
    \\) {
    \\    constexpr sampler atlas_sampler(address::clamp_to_edge, filter::linear);
    \\    return atlas.sample(atlas_sampler, in.uv) * in.opacity;
    \\}
;

/// Kitty graphics phase-1 resources are straight-alpha RGBA8 textures. The
/// quad is in point space while UVs cover the resource's backing pixels.
pub const image =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct ImageInstance {
    \\    packed_float2 origin;
    \\    packed_float2 size;
    \\    packed_float4 uv;
    \\};
    \\
    \\struct ImageOut {
    \\    float4 position [[position]];
    \\    float2 uv;
    \\};
    \\
    \\constant float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
    \\
    \\vertex ImageOut image_vertex(
    \\    uint vid [[vertex_id]],
    \\    const device ImageInstance* instances [[buffer(0)]],
    \\    constant float2& viewport [[buffer(1)]]
    \\) {
    \\    ImageInstance inst = instances[0];
    \\    float2 corner = corners[vid];
    \\    float2 pos = inst.origin + corner * inst.size;
    \\    float2 ndc = (pos / viewport) * 2.0 - 1.0;
    \\    ndc.y = -ndc.y;
    \\    ImageOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.uv = float2(mix(inst.uv.x, inst.uv.z, corner.x),
    \\                    mix(inst.uv.y, inst.uv.w, corner.y));
    \\    return out;
    \\}
    \\
    \\fragment float4 image_fragment(
    \\    ImageOut in [[stage_in]],
    \\    texture2d<float> source [[texture(0)]]
    \\) {
    \\    constexpr sampler image_sampler(address::clamp_to_edge, filter::linear);
    \\    return source.sample(image_sampler, in.uv);
    \\}
;
