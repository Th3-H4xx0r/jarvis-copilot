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
// Reference: a frosted glass blob. The frost is a *volume* — thick at the left
// where it goes fully white with fine radial brush streaks, thinning to almost
// nothing on the right — wrapped around an off-centre core that folds hard from
// near-black through cobalt to electric cyan, textured by very fine ridges.
[[ stitchable ]] half4 liquidOrb(float2 pos, half4 inColor,
                                  float2 size, float t, float bright, float breathe,
                                  half4 deepH, half4 cyanH, half4 shellTintH)
{
    float4 deep = float4(deepH), cyan = float4(cyanH), shellTint = float4(shellTintH);
    float2 c = size * 0.5;
    // 0.312 = the Canvas orb's radius under the 1.7× bleed (kFill = 1 in VoiceOrb).
    float R = min(size.x, size.y) * 0.5 * 0.312 * breathe;
    float2 p = (pos - c) / R;

    // Silhouette: slow, large bulge + small ripple + sway.
    float2 dir = length(p) > 1e-4 ? normalize(p) : float2(1.0, 0.0);
    float ang = atan2(dir.y, dir.x);
    float bulge = fbm3(float3(dir * 1.1, 0.0), t * 0.5) - 0.5;
    float ripple = fbm3(float3(dir * 3.0 + 4.7, 0.0), t * 1.1) - 0.5;
    float sway = 0.03 * sin(ang * 2.0 + t * 0.5) + 0.02 * sin(ang * 3.0 - t * 0.33 + 1.0);
    float w = 1.0 + 0.11 * bulge + 0.03 * ripple + sway;
    float d = length(p) / w;

    if (d > 1.35) { return half4(0.0); }
    float glow = smoothstep(1.35, 1.0, d);
    glow = glow * glow * 0.14 * bright;
    float3 glowCol = mix(float3(1.0), cyan.rgb, 0.5) * glow;
    if (d > 1.0) { return half4(half3(glowCol), half(glow)); }

    float2 q = p / w;                                   // unit disc, y down
    float r = length(q);
    float zN = sqrt(max(0.0, 1.0 - r * r));
    float3 n = normalize(float3(q, zN));

    // Refraction through the glass: the core magnifies toward the centre and
    // smears toward the edge. Sample the core in lens-bent coordinates.
    float2 qr = q * mix(0.86, 1.18, r * r);

    // ── Core blob (off-centre, toward the right) ──
    float2 coreC = float2(0.11, 0.05) + 0.03 * float2(sin(t * 0.31), cos(t * 0.27));
    float2 cq = qr - coreC;
    float2 cdir = length(cq) > 1e-4 ? normalize(cq) : float2(1.0, 0.0);
    float coreR = 0.80 + 0.07 * (fbm3(float3(cdir * 1.6 + 2.2, 0.0), t * 0.4) - 0.5) * 2.0;
    float cd = length(cq) - coreR;                      // <0 inside the core
    // Boundary is smeared more on the left (thick frost) than on the right.
    float smear = mix(0.10, 0.34, smoothstep(0.35, -0.55, cq.x));

    // Colour fold: near-black → cobalt → cyan along a warped diagonal.
    float3 flow = float3(t * 0.06, -t * 0.05, t * 0.04);
    float warpN = fbm3(float3(cq * 1.3 + 6.0, 0.3) + flow, t) - 0.5;
    float u = dot(cq, normalize(float2(0.88, 0.32))) + 0.28 * warpN;
    float3 navy = deep.rgb * 0.16;                                   // near-black blue
    float3 cobalt = float3(0.08, 0.10, 0.96);
    float3 cyanS = mix(float3(0.0, 0.88, 1.0), cyan.rgb, 0.2);
    float3 core = mix(navy, cobalt, smoothstep(-0.55, -0.05, u));
    core = mix(core, float3(0.22, 0.26, 1.0), 0.45 * smoothstep(-0.40, 0.0, u));   // brighter cobalt at the fold
    float3 cyanG = cyanS * (0.78 + 0.28 * clamp(-cq.y + 0.3, 0.0, 1.0));
    core = mix(core, cyanG, smoothstep(0.0, 0.14, u));              // hard fold
    // A lighter cobalt lobe and a dark inner pocket give the fold volume.
    float lobe = fbm3(float3(cq * 2.0 + 11.0, 0.1) + flow, t);
    core = mix(core, cobalt * 1.15, 0.25 * smoothstep(0.5, 0.8, lobe) * smoothstep(-0.05, -0.5, u));
    core *= 1.0 - 0.45 * smoothstep(0.5, 0.85, fbm3(float3(cq * 1.5 + 21.0, 0.0), t * 0.3)) * smoothstep(0.0, -0.6, u);
    // Very fine ridges across the core — a curved scanline texture.
    float ridge = 0.5 + 0.5 * sin(cq.y * 150.0 + 18.0 * cq.x * cq.x + 6.0 * warpN);
    core *= 0.92 + 0.10 * ridge;
    // Cyan blooms a little past the fold.
    core += cyanS * 0.15 * smoothstep(0.0, 0.35, u) * (1.0 - smoothstep(0.35, 0.9, u));
    // Lighter centre in the cyan lobe.
    float2 cc = cq - float2(0.38, -0.08);
    core = mix(core, mix(cyanS, float3(1.0), 0.35), 0.6 * exp(-dot(cc, cc) * 6.0) * smoothstep(0.0, 0.2, u));

    // ── Frosted glass volume ──
    // Thick where we are far outside the core (left), thin near it (right).
    float thick = smoothstep(-smear, 0.16, cd);
    // Fine radial brush streaks in the frost.
    float streak = fbm3(float3(dir * 2.4, r * 1.5 + 0.7), t * 0.15);
    float streakF = vnoise(float3(dir * 9.0, r * 2.5 + 2.0 + t * 0.05));
    // Brushed white strands reaching from the frost over the core's edge.
    float strand = vnoise(float3(dir * 11.0, r * 1.2 + 5.0 + t * 0.04));
    strand = smoothstep(0.62, 0.95, strand) * smoothstep(0.35, 0.85, r) * (1.0 - thick) * smoothstep(0.45, -0.3, cq.x);
    float frostA = clamp(thick + 0.38 * strand, 0.0, 1.0);
    // Bright frost, lit from the upper-left, with faint brushed streaks.
    float frostLit = 0.93 + 0.07 * dot(q, normalize(float2(-0.6, -0.8)));
    float3 frostCol = float3(1.0) * clamp(frostLit + 0.07 * (streak - 0.5) * 2.0 + 0.04 * (streakF - 0.5) * 2.0, 0.0, 1.0);
    // Glass gets a touch darker and cooler toward the rim (thickness), bar the highlight.
    frostCol *= 1.0 - 0.14 * smoothstep(0.7, 1.0, r);
    frostCol = mix(frostCol, frostCol * float3(0.90, 0.95, 1.0), smoothstep(0.6, 1.0, r));
    frostCol = mix(frostCol, mix(float3(1.0), cyanS, 0.35), 0.25 * (1.0 - thick));
    // Body haze: a faint white veil over everything, stronger toward the rim.
    float veil = 0.06 + 0.10 * r * r;
    // Thin crisp rim (narrow Fresnel) and a soft specular from upper-left.
    float fres = pow(1.0 - max(dot(n, float3(0, 0, 1)), 0.0), 6.0);
    float rimLine = smoothstep(0.92, 0.985, r) * 0.35 + fres * 0.30;
    float3 l = normalize(float3(-0.55, -0.65, 0.55));
    float spec = pow(max(dot(n, normalize(l + float3(0, 0, 1))), 0.0), 60.0) * 0.35;

    float3 white = mix(float3(1.0), shellTint.rgb, 0.08);
    float3 col = mix(core, frostCol, frostA);
    col = mix(col, white, veil);
    col += white * rimLine + white * spec;
    col *= bright;

    // Alpha: the glass is nearly opaque where frosted, slightly see-through in
    // the clear right side, and the AA'd silhouette.
    float alpha = clamp(0.96 + rimLine, 0.0, 1.0);
    alpha *= smoothstep(1.0, 0.988, d);
    return half4(half3(col * alpha), half(alpha));
}
