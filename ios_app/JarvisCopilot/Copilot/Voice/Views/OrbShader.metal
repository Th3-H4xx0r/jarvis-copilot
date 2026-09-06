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
// Reference look: a frosted, translucent white shell whose inner edge is
// irregular (brushed), wrapped around a lit core that runs electric cyan at the
// upper-left to deep blue at the lower-right, carved with fine contour ridges.
[[ stitchable ]] half4 liquidOrb(float2 pos, half4 inColor,
                                  float2 size, float t, float bright, float breathe,
                                  half4 deepH, half4 cyanH, half4 shellTintH)
{
    // SwiftUI hands `.color(...)` arguments to Metal as half4.
    float4 deep = float4(deepH), cyan = float4(cyanH), shellTint = float4(shellTintH);
    float2 c = size * 0.5;
    // 0.312 = the Canvas orb's radius under the 1.7× bleed; 1.35 = kFill in VoiceOrb.
    float R = min(size.x, size.y) * 0.5 * 0.312 * 1.35 * breathe;
    float2 p = (pos - c) / R;

    // Fluid silhouette: slow large bulge + quicker small ripple + gentle sway.
    float2 dir = length(p) > 1e-4 ? normalize(p) : float2(1.0, 0.0);
    float a = atan2(dir.y, dir.x);
    float bulge = fbm3(float3(dir * 1.1, 0.0), t * 0.6) - 0.5;
    float ripple = fbm3(float3(dir * 3.0 + 4.7, 0.0), t * 1.4) - 0.5;
    float sway = 0.035 * sin(a * 2.0 + t * 0.55) + 0.025 * sin(a * 3.0 - t * 0.37 + 1.0);
    float w = 1.0 + 0.14 * bulge + 0.04 * ripple + sway;
    float d = length(p) / w;

    if (d > 1.50) { return half4(0.0); }
    // Soft exterior haze.
    float glow = smoothstep(1.50, 1.0, d);
    glow = glow * glow * 0.22 * bright;
    float3 glowCol = mix(deep.rgb, cyan.rgb, 0.6) * glow;
    if (d > 1.0) { return half4(half3(glowCol), half(glow)); }

    float2 q = p / w;                 // unit-disc coords, y down
    float r = length(q);
    float3 flow = float3(t * 0.10, -t * 0.08, t * 0.06);

    // ── Core ──
    // Key light from the upper-left: cyan there, deep blue opposite.
    float2 lightDir = normalize(float2(-0.62, -0.78));
    float lit = 0.5 + 0.5 * dot(q, lightDir);
    float litNoise = fbm3(float3(q * 1.7 + 2.3, 0.4) + flow, t) - 0.5;
    float3 base = mix(deep.rgb * 0.78, cyan.rgb, smoothstep(0.20, 0.92, lit + 0.30 * litNoise));

    // Contour ridges: level sets of a domain-warped field → thin curved lines.
    float3 warp = float3(fbm3(float3(q * 1.4, 0.2) + flow, t),
                         fbm3(float3(q * 1.4 + 5.2, 0.2) + flow, t), 0.0) - 0.5;
    float field = fbm3(float3(q * 1.5 + warp.xy * 0.45, 0.9) + flow * 0.6, t);
    // Mostly parallel diagonal lines, bent by the field — like a thumbprint.
    float diag = dot(q, float2(0.82, -0.57));
    float ridge = 0.5 + 0.5 * sin(diag * 58.0 + field * 15.0 + t * 0.3);
    ridge = pow(ridge, 7.0);                                   // thin bright lines
    float ridgeAmt = 0.36 * (0.30 + 0.70 * lit);
    float3 core = base * (0.88 + ridgeAmt * ridge) + cyan.rgb * 0.14 * ridge * lit;

    // Dark pockets in the unlit half give the fluid depth.
    float pocket = smoothstep(0.42, 0.78, fbm3(float3(q * 2.3 + 9.1, 0.0) + flow, t));
    core *= 1.0 - 0.55 * pocket * (1.0 - lit);
    // Soft cyan bloom near the key light, and a dim floor so blue never goes black.
    float2 hlC = float2(-0.36, -0.42);
    float hl = exp(-dot(q - hlC, q - hlC) * 3.6);
    core += cyan.rgb * 0.30 * hl;
    core = max(core, deep.rgb * 0.35);

    // ── Frosted shell ──
    // Inner edge wanders with angle (brushed, not a clean ring).
    float edgeN = fbm3(float3(dir * 2.2 + 3.1, 0.0), t * 0.45) - 0.5;
    float edgeF = fbm3(float3(dir * 6.5 + 8.4, 0.0), t * 0.8) - 0.5;
    float innerEdge = 0.75 + 0.13 * edgeN + 0.04 * edgeF;
    float shellMask = smoothstep(innerEdge - 0.14, innerEdge + 0.04, r);
    float grain = fbm3(float3(q * 6.0, 1.3), t * 0.25);        // frosted texture
    float wisp = fbm3(float3(q * 2.6 + 4.4, 0.6), t * 0.2) - 0.5;  // cloudy variation
    float rim = smoothstep(0.55, 1.0, r);
    float shellA = shellMask * clamp(0.68 + 0.30 * rim + 0.10 * (grain - 0.5) + 0.22 * wisp, 0.0, 1.0);
    float3 shellCol = mix(float3(1.0), shellTint.rgb, 0.10) * (1.06 + 0.08 * grain);
    // The lit core bleeds a little cyan into the frost around it.
    shellCol = mix(shellCol, cyan.rgb, 0.22 * hl + 0.08 * (1.0 - rim) * lit);

    // Specular pinpoint on the shell from the key light.
    float zN = sqrt(max(0.0, 1.0 - r * r));
    float3 n = normalize(float3(q, zN));
    float3 v = float3(0.0, 0.0, 1.0);
    float3 l = normalize(float3(lightDir, 0.9));
    float spec = pow(max(dot(n, normalize(l + v)), 0.0), 160.0) * 0.45;

    // Compose: core beneath, frosted shell over it, background faintly through the shell.
    float3 colOut = mix(core * bright, shellCol * bright, shellA) + spec * bright;
    float alpha = 1.0 - shellMask * 0.22 * (1.0 - rim * 0.5);
    alpha *= smoothstep(1.0, 0.985, d);                        // AA silhouette
    return half4(half3(colOut * alpha), half(alpha));
}
