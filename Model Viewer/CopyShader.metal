#include <metal_stdlib>
using namespace metal;

// -------------------------------------------------------
// Vertex I/O structs
// -------------------------------------------------------
struct CopyVertexIn {
    float3 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct CopyVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// -------------------------------------------------------
// Minimal pass-through vertex shader
// (Draws a full-screen quad if SceneKit sets it up.)
// -------------------------------------------------------
vertex CopyVertexOut copyVertex(CopyVertexIn in [[stage_in]])
{
    CopyVertexOut out;
    out.position = float4(in.position.xy, 0.0, 1.0);
    out.texCoord = float2((in.position.x + 1.0) * 0.5, (1.0 - in.position.y) * 0.5);
    return out;
}

// -------------------------------------------------------
// Simple fragment shader that "just copies" the texture
// without requiring an externally bound sampler.
// -------------------------------------------------------
fragment float4 copyFragment(CopyVertexOut in [[stage_in]],
                             texture2d<float> inputTexture [[texture(0)]])
{
    // Inline sampler so SceneKit won't complain that we're missing one.
    constexpr sampler linearSampler(address::clamp_to_edge,
                                    filter::linear);

    // Simply sample the input texture using UV coordinates.
    return inputTexture.sample(linearSampler, in.texCoord);
}
