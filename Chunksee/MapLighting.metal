#include <metal_stdlib>
using namespace metal;

// One encoded unit normal per map pixel. Black marks water, whose palette has no relief.
// The filter runs in linear sRGB; the normal image is also explicitly linear sRGB.
[[ stitchable ]] half4 mapSavedLighting(float2 position, half4 color, texture2d<half> normals,
                                      float4 rect, float3 direction, float3 tint, float protectsWater) {
    if (color.a == 0) return color;
    constexpr sampler point(coord::normalized, address::clamp_to_edge, filter::nearest);
    float3 encoded = float3(normals.sample(point, (position - rect.xy) / rect.zw).rgb);
    bool water = all(encoded < float3(0.002));
    if (water && protectsWater > 0) return color;
    float relief = 1;
    if (!water) {
        float3 normal = normalize(encoded * 2 - 1);
        relief = clamp(1 + 0.3 * (dot(normal, direction) - direction.y), 0.75, 1.2);
    }
    return half4(min(color.rgb * half3(tint * relief), half3(color.a)), color.a);
}
