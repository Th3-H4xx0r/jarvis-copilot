#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Liquid-glass orb, per pixel.
//
// Techniques (see the research notes in the commit):
//   • silhouette  — sphere SDF displaced by low-frequency 3D fbm, so the blob
//                   deforms like fluid rather than on fixed harmonics;
//   • shell       — Schlick Fresnel R0 + (1-R0)(1-n·v)^k with a broad exponent
//                   for a frosted glass edge, plus a thickness term;
//   • core        — volumetric raymarch between the sphere's near and far hits,
//                   density from domain-warped fbm f(p + fbm(p)) with time on the
//                   lowest and highest octaves (bulk flow + fine turbulence),
//                   front-to-back alpha compositing, Beer–Lambert absorption,
//                   colour by density (deep blue → cyan), tanh tonemap;
//   • lighting    — Blinn-Phong specular from an upper-left key, soft caustic.

// ── noise ────────────────────────────────────────────────────────────────────
static float hash31(float3 p) {
    p = fract(p * 0.3183099 + float3(0.1, 0.2, 0.3));
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static float vnoise(float3 p) {                       // value noise, C1 smooth
    float3 i = floor(p), f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float n000 = hash31(i), n100 = hash31(i + float3(1,0,0));
    float n010 = hash31(i + float3(0,1,0)), n110 = hash31(i + float3(1,1,0));
    float n001 = hash31(i + float3(0,0,1)), n101 = hash31(i + float3(1,0,1));
    float n011 = hash31(i + float3(0,1,1)), n111 = hash31(i + float3(1,1,1));
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

// Rotation between octaves breaks lattice alignment (Quilez).
constant float3x3 kRot = float3x3(float3( 0.00,  0.80,  0.60),
                                  float3(-0.80,  0.36, -0.48),
                                  float3(-0.60, -0.48,  0.64));

static float fbm3(float3 p, float t) {
    float f = 0.0;
    f += 0.5000 * vnoise(p + float3(0.0, 0.0, t * 0.35));   // low octave: bulk flow
    p = kRot * p * 2.02;
    f += 0.2500 * vnoise(p);
    p = kRot * p * 2.03;
    f += 0.1250 * vnoise(p + float3(sin(t * 0.7), 0.0, 0.0)); // high octave: turbulence
    return f / 0.875;
}

// ── orb ──────────────────────────────────────────────────────────────────────
[[ stitchable ]] half4 liquidOrb(float2 pos, half4 inColor,
                                  float2 size, float t, float bright,
                                  half4 deepH, half4 cyanH, half4 shellTintH)
{
    // SwiftUI hands `.color(...)` arguments to Metal as half4.
    float4 deep = float4(deepH), cyan = float4(cyanH), shellTint = float4(shellTintH);
    float2 c = size * 0.5;
    float R = min(size.x, size.y) * 0.5 * 0.312;   // = VoiceOrbGeometry radius (0.53 × base) under the 1.7× bleed
    float2 p = (pos - c) / R;

    // Fluid silhouette: radius displaced by fbm of the direction (+ time).
    float2 dir = length(p) > 1e-4 ? normalize(p) : float2(1.0, 0.0);
    float disp = fbm3(float3(dir * 1.6, 0.0), t) - 0.5;           // -0.5..0.5
    float w = 1.0 + 0.11 * disp;
    float d = length(p) / w;

    if (d > 1.40) { return half4(0.0); }
    // Exterior glow.
    float glow = smoothstep(1.40, 1.0, d);
    glow = glow * glow * 0.20 * bright;
    float3 glowCol = mix(deep.rgb, cyan.rgb, 0.45) * glow;
    if (d > 1.0) { return half4(half3(glowCol), half(glow)); }

    // Sphere hits along the view ray (orthographic, camera at +z).
    float2 q = p / w;
    float zN = sqrt(max(0.0, 1.0 - dot(q, q)));                   // near surface z
    float3 n = normalize(float3(q, zN));
    float3 v = float3(0.0, 0.0, 1.0);
    float NdotV = max(dot(n, v), 0.0);

    // Schlick Fresnel, broad exponent for a frosted (not razor-thin) rim.
    float R0 = 0.04;
    float fres = R0 + (1.0 - R0) * pow(1.0 - NdotV, 3.2);
    // Glass thickness seen through the shell grows toward the edge.
    float thick = 1.0 - zN;

    // ── Volumetric core: march from the near hit to the far hit. ──
    const int STEPS = 8;
    float3 ro = float3(q, zN);
    float3 rd = float3(0.0, 0.0, -1.0);
    float segment = 2.0 * zN;                                       // chord length
    float dt = segment / float(STEPS);
    float3 acc = float3(0.0);
    float alphaAcc = 0.0;
    float3 flow = float3(t * 0.12, -t * 0.09, t * 0.07);
    for (int i = 0; i < STEPS; ++i) {
        float3 sp = ro + rd * (dt * (float(i) + 0.5));
        // Domain warp: f(p + fbm(p)).
        float3 warp = float3(fbm3(sp * 1.3 + flow, t),
                             fbm3(sp * 1.3 + flow + 7.1, t),
                             fbm3(sp * 1.3 + flow + 13.7, t)) - 0.5;
        float dens = fbm3(sp * 1.8 + warp * 0.9 + flow * 0.5, t);
        dens = smoothstep(0.28, 0.72, dens);                        // carve pockets
        // Colour by density: sparse = deep blue, dense = cyan; lit from upper-left.
        float lit = clamp(0.5 + 0.6 * dot(normalize(float3(-0.6, 0.7, 0.4)), normalize(sp + 1e-3)), 0.0, 1.0);
        float3 col = mix(deep.rgb * 0.9, cyan.rgb, dens * (0.55 + 0.45 * lit));
        // Beer–Lambert: light travelling deeper into the volume is absorbed.
        float depthIn = dt * (float(i) + 0.5);
        float trans = exp(-1.4 * depthIn);
        float a = dens * 0.55 * (0.45 + 0.55 * trans);
        acc += (1.0 - alphaAcc) * a * col;
        alphaAcc += (1.0 - alphaAcc) * a;
        if (alphaAcc > 0.985) { break; }
    }
    // Fine contour ridges (≈ -28°) riding on the core, faint.
    float2 rq = float2(q.x * cos(-0.49) - q.y * sin(-0.49), q.x * sin(-0.49) + q.y * cos(-0.49));
    acc *= 0.95 + 0.05 * sin(rq.y * 90.0 + t * 1.1);
    // Tonemap the glow so the dense cyan reads luminous without clipping.
    acc = tanh(acc * 2.0 * bright);

    // ── Shell + lighting ──
    float shell = clamp(fres * 0.80 + thick * thick * thick * 0.35, 0.0, 1.0);
    float3 shellCol = mix(float3(1.0), shellTint.rgb, 0.30);
    float3 l = normalize(float3(-0.55, 0.65, 0.55));
    float spec = pow(max(dot(n, normalize(l + v)), 0.0), 140.0) * 0.55;
    float3 l2 = normalize(float3(0.6, -0.5, 0.35));
    float caustic = pow(max(dot(n, normalize(l2 + v)), 0.0), 36.0) * 0.30 * fres;

    // Compose: core seen through the shell, shell on top, highlights last.
    float coreVis = 1.0 - shell * 0.65;
    float3 colOut = acc * coreVis + shellCol * shell * bright + float3(spec + caustic) * bright;
    float alpha = clamp(max(shell, alphaAcc * 0.92) + spec, 0.0, 1.0);
    alpha *= smoothstep(1.0, 0.985, d);                              // AA silhouette
    return half4(half3(colOut * alpha), half(alpha));
}
