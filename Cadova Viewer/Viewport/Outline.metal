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
// outside of the part. To keep the band's edges crisp but not pixelated, each binary mask is first
// blurred (turning the diagonal pixel staircase into a smooth gradient that follows the true
// edge), then re-sharpened to a ~1px anti-aliased step via `aaStep` — so the edge stays sharp
// without the stair-stepping. `outer - inner` keeps the outline off the part's interior.
constexpr sampler kSmoothSampler(coord::normalized, filter::linear, address::clamp_to_edge);

// Average a mask's green channel over a 3×3 box of single-texel offsets around `uv`. With linear
// filtering each tap already averages four texels, so the effective footprint is ~5×5.
static float blurredMask(texture2d<float, access::sample> tex, float2 uv)
{
    float2 texel = 1.0 / float2(tex.get_width(), tex.get_height());
    float sum = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            sum += tex.sample(kSmoothSampler, uv + float2(float(dx), float(dy)) * texel).g;
        }
    }
    return sum / 9.0;
}

// Coverage of a smoothly-varying value past 0.5, anti-aliased over ~1px using its screen-space
// rate of change. Turns the blurred gradient back into a sharp, smooth-edged step.
static float aaStep(float v)
{
    float w = max(fwidth(v), 1e-5);
    return clamp((v - 0.5) / w + 0.5, 0.0, 1.0);
}

fragment half4 outline_combine_fragment(outline_vertex_out vert [[stage_in]],
                                        texture2d<float, access::sample> colorSampler [[texture(0)]],
                                        texture2d<float, access::sample> maskSampler [[texture(1)]],
                                        texture2d<float, access::sample> dilatedSampler [[texture(2)]],
                                        constant OutlineInputs& inputs [[buffer(0)]])
{
    float4 sceneColor = colorSampler.sample(kSmoothSampler, vert.uv);
    float inner = aaStep(blurredMask(maskSampler, vert.uv));
    float outer = aaStep(blurredMask(dilatedSampler, vert.uv));

    float edge = clamp(outer - inner, 0.0, 1.0);
    float3 rgb = mix(sceneColor.rgb, inputs.outlineColor, edge);
    return half4(float4(rgb, 1.0));
}
