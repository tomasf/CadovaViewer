#include <metal_stdlib>
using namespace metal;
#include <SceneKit/scn_metal>

// SCNTechnique post-process that draws a crisp outline around the geometry named "OutlineTarget".
// Two passes: a mask pass renders that geometry as a solid silhouette into an offscreen buffer,
// then full-screen quad passes dilate the silhouette and composite a band over the rendered scene.
// The surface itself is left untouched, so a highlighted part looks normal (or, for a hidden part,
// keeps its faint ghost) and simply gains an outline. Adapted from laanlabs/SCNTechniqueGlow.

// SceneKit fills the per-node buffer with these four matrices in this order; we only need the
// MVP (the last one), but the struct layout must match so the offset is correct.
struct outline_node_t {
    float4x4 modelTransform;
    float4x4 modelViewTransform;
    float4x4 normalTransform;
    float4x4 modelViewProjectionTransform;
};

struct outline_vertex_in {
    float4 position [[attribute(SCNVertexSemanticPosition)]];
};

struct outline_vertex_out {
    float4 position [[position]];
    float2 uv;
};

typedef struct {
    float3 outlineColor;
} OutlineInputs;

// Outline half-thickness, in MASK-texture pixels. Supplied by the app as points × the display's
// backing scale, so the band looks the same thickness on retina and non-retina displays.
typedef struct {
    float radius;
} OutlineRadius;

// MARK: - Mask pass: render the tagged geometry as a solid silhouette.

vertex outline_vertex_out outline_mask_vertex(outline_vertex_in in [[stage_in]],
                                              constant outline_node_t& scn_node [[buffer(0)]])
{
    outline_vertex_out out;
    out.position = scn_node.modelViewProjectionTransform * float4(in.position.xyz, 1.0);
    return out;
}

fragment half4 outline_mask_fragment(outline_vertex_out in [[stage_in]])
{
    return half4(1.0);
}

// MARK: - Outline pass: trace a line just outside the silhouette over the scene colour.

vertex outline_vertex_out outline_quad_vertex(outline_vertex_in in [[stage_in]])
{
    outline_vertex_out out;
    out.position = in.position;
    out.uv = float2((in.position.x + 1.0) * 0.5, 1.0 - (in.position.y + 1.0) * 0.5);
    return out;
}

// The band is produced by a separable max-dilation (a horizontal then a vertical pass), so cost
// is O(radius) per pass rather than the O(radius²) of sampling a filled disk in one pass —
// keeping the view responsive even with a thick outline.

constexpr sampler kOutlineSampler(coord::normalized, filter::nearest, address::clamp_to_edge);
constant int kMaxOutlineRadius = 64; // loop cap so the dynamic radius can't run away

// Horizontal dilation: max of the silhouette over [-radius, radius] in x.
fragment half4 outline_dilate_h(outline_vertex_out vert [[stage_in]],
                                texture2d<float, access::sample> maskSampler [[texture(0)]],
                                constant OutlineRadius& params [[buffer(0)]])
{
    int radius = clamp(int(round(params.radius)), 0, kMaxOutlineRadius);
    float texel = 1.0 / float(maskSampler.get_width());
    float m = 0.0;
    for (int dx = -radius; dx <= radius; dx++) {
        m = max(m, maskSampler.sample(kOutlineSampler, vert.uv + float2(float(dx) * texel, 0.0)).g);
    }
    return half4(m, m, m, 1.0);
}

// Vertical dilation: max over [-radius, radius] in y. Together with the horizontal pass this
// grows the silhouette by `radius` pixels in every direction (a square structuring element).
fragment half4 outline_dilate_v(outline_vertex_out vert [[stage_in]],
                                texture2d<float, access::sample> maskSampler [[texture(0)]],
                                constant OutlineRadius& params [[buffer(0)]])
{
    int radius = clamp(int(round(params.radius)), 0, kMaxOutlineRadius);
    float texel = 1.0 / float(maskSampler.get_height());
    float m = 0.0;
    for (int dy = -radius; dy <= radius; dy++) {
        m = max(m, maskSampler.sample(kOutlineSampler, vert.uv + float2(0.0, float(dy) * texel)).g);
    }
    return half4(m, m, m, 1.0);
}

// Composite: the outline is the dilated silhouette minus the original — a solid band hugging the
// outside of the part. The surface inside the silhouette is left as rendered.
fragment half4 outline_combine_fragment(outline_vertex_out vert [[stage_in]],
                                        texture2d<float, access::sample> colorSampler [[texture(0)]],
                                        texture2d<float, access::sample> maskSampler [[texture(1)]],
                                        texture2d<float, access::sample> dilatedSampler [[texture(2)]],
                                        constant OutlineInputs& inputs [[buffer(0)]])
{
    float4 sceneColor = colorSampler.sample(kOutlineSampler, vert.uv);

    if (maskSampler.sample(kOutlineSampler, vert.uv).g > 0.5) {
        return half4(sceneColor); // inside the silhouette
    }

    float edge = clamp(dilatedSampler.sample(kOutlineSampler, vert.uv).g, 0.0, 1.0);
    float3 rgb = mix(sceneColor.rgb, inputs.outlineColor, edge);
    return half4(float4(rgb, 1.0));
}
