#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Liquid-glass orb, rendered per pixel.
//
// A sphere whose silhouette wobbles with three slow harmonics; a thick frosted
// shell driven by Fresnel (bright where the surface turns away from the eye);
// a volumetric two-tone core (deep blue → cyan) that drifts inside and carries
// fine contour ridges; a specular highlight from an upper-left light; and a soft
// exterior glow. Output is premultiplied; everything outside the glow is clear.

static float wobble(float a, float t) {
    return 1.0
        + 0.030 * sin(3.0 * a + t * 0.70)
        + 0.022 * sin(5.0 * a - t * 0.45 + 1.3)
        + 0.018 * sin(2.0 * a + t * 0.30 + 2.1)
        + 0.012 * sin(7.0 * a + t * 0.90 + 0.4);
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

[[ stitchable ]] half4 liquidOrb(float2 pos, half4 inColor,
                                  float2 size, float t, float bright,
                                  float4 deep, float4 cyan, float4 shellTint)
{
    float2 c = size * 0.5;
    float R = min(size.x, size.y) * 0.5 * 0.60;          // orb radius in points
    float2 p = (pos - c) / R;                              // orb space, radius 1
    float a = atan2(p.y, p.x);
    float w = wobble(a, t);
    float d = length(p) / w;                               // 1.0 = silhouette

    // Exterior glow, fading out by 1.35 R.
    if (d > 1.35) { return half4(0.0); }
    float glow = smoothstep(1.35, 1.0, d) * 0.22 * bright;
    float3 glowCol = mix(deep.rgb, cyan.rgb, 0.5) * glow;
    if (d > 1.0) {
        return half4(half3(glowCol), half(glow));
    }

    // Sphere geometry.
    float z = sqrt(max(0.0, 1.0 - d * d));
    float3 n = normalize(float3(p / w, z));
    float3 v = float3(0.0, 0.0, 1.0);
    float fres = pow(1.0 - max(dot(n, v), 0.0), 2.4);     // 0 centre → 1 at the rim

    // Volumetric core: sample a slowly moving field along the refracted ray.
    float2 q = p / w;
    float2 flow = float2(sin(t * 0.37), cos(t * 0.29)) * 0.35;
    float field = 0.5 + 0.5 * sin(2.2 * (q.x + flow.x) + 1.4 * (q.y - flow.y) + t * 0.5)
                        * cos(1.7 * (q.y + flow.y) - 0.9 * q.x - t * 0.4);
    float diag = dot(q, normalize(float2(-1.0, 1.0)));     // lit from upper-left
    float mixAmt = clamp(field * 0.6 + (0.5 - diag) * 0.6, 0.0, 1.0);
    float3 core = mix(deep.rgb, cyan.rgb, mixAmt);
    // Depth shading: darker toward the far/bottom-right, brighter toward the light.
    core *= 0.55 + 0.65 * clamp(0.5 - diag * 0.9, 0.0, 1.0) + 0.35 * z;
    // Fine contour ridges (≈ -28°), moving slowly.
    float2 rq = float2(q.x * cos(-0.49) - q.y * sin(-0.49), q.x * sin(-0.49) + q.y * cos(-0.49));
    float ridge = 0.86 + 0.14 * sin(rq.y * 64.0 + t * 1.2) * (1.0 - fres);
    core *= ridge;
    // The core lives inside the glass, fading under the shell.
    float coreMask = smoothstep(1.0, 0.62, d);

    // Frosted shell: Fresnel-driven white with a soft inner edge.
    float shell = smoothstep(0.55, 1.0, fres) * 0.92 + smoothstep(0.80, 1.0, d) * 0.55;
    shell = clamp(shell, 0.0, 1.0);
    float3 shellCol = mix(float3(1.0), shellTint.rgb, 0.18);

    // Specular from an upper-left light, plus a soft caustic bottom-right.
    float3 l = normalize(float3(-0.55, 0.65, 0.55));
    float3 h = normalize(l + v);
    float spec = pow(max(dot(n, h), 0.0), 70.0) * 0.9;
    float3 l2 = normalize(float3(0.6, -0.5, 0.35));
    float caustic = pow(max(dot(n, normalize(l2 + v)), 0.0), 40.0) * 0.35 * fres;

    float3 col = core * coreMask * 0.95 + shellCol * shell + float3(spec + caustic);
    col *= bright;
    // Slight surface grain so the shell reads as frosted, not plastic.
    col += (hash21(pos) - 0.5) * 0.03;
    float alpha = clamp(max(shell, coreMask * 0.85) + spec, 0.0, 1.0);
    // Anti-aliased silhouette.
    float edge = smoothstep(1.0, 0.985, d);
    alpha *= edge;
    return half4(half3(col * alpha), half(alpha));
}
