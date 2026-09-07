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
// A dark glass sphere lit from within by a sloshing liquid interface: thin
// Fresnel rim, soft cool reflection on the upper dome, a horizontal wave whose
// ends burn warm orange where they meet the rim and run cool white-blue across
// the middle, a warm lobe filling one side of the wave, and a blue pool glow
// (with a pin of white) at the bottom. The silhouette is a perfect circle.

static float waveHeight(float x, float t) {
    float level = 0.10 * sin(t * 0.37) + 0.04 * sin(t * 0.91 + 1.7);
    float amp = 0.15 + 0.06 * sin(t * 0.53 + 0.4);
    return level + amp * sin(x * 1.55 + t * 0.62) + 0.045 * sin(x * 3.1 - t * 1.25 + 0.8);
}

[[ stitchable ]] half4 liquidOrb(float2 pos, half4 inColor,
                                  float2 size, float t, float bright, float breathe,
                                  half4 deepH, half4 cyanH, half4 shellTintH)
{
    float3 cool = mix(float3(0.62, 0.82, 1.0), float3(cyanH.rgb), 0.15);
    float3 orange = float3(1.0, 0.55, 0.14);
    float3 ember = float3(0.95, 0.30, 0.08);
    float3 pool = float3(0.22, 0.52, 1.0);

    float2 c = size * 0.5;
    // 0.312 = the Canvas orb's radius under the 1.7× bleed (kFill = 1 in VoiceOrb).
    float R = min(size.x, size.y) * 0.5 * 0.312 * breathe;
    float2 q = (pos - c) / R;                          // unit disc, y down
    float r = length(q);
    if (r > 1.30) { return half4(0.0); }

    // Voice reactivity: `breathe` is the radius ratio the geometry computes
    // from the mic / playback level (1.0 quiet). The liquid sloshes harder and
    // burns brighter as it rises.
    float react = clamp((breathe - 1.0) / 0.45, 0.0, 1.0);

    // Wave interface and the two rim hotspots where it meets the glass.
    float hx = waveHeight(q.x, t) * (1.0 + 1.1 * react) + 0.05 * react * sin(t * 6.0);
    float dy = q.y - hx;
    float hl = waveHeight(-0.97, t) * (1.0 + 1.1 * react), hr = waveHeight(0.97, t) * (1.0 + 1.1 * react);
    float2 pL = float2(-sqrt(max(0.0, 1.0 - hl * hl)), hl);
    float2 pR = float2( sqrt(max(0.0, 1.0 - hr * hr)), hr);
    float dL = length(q - pL), dR = length(q - pR);
    float hot = exp(-dL * dL * 55.0) + exp(-dR * dR * 55.0);            // tight cores
    float hotBloom = exp(-dL * dL * 5.5) + exp(-dR * dR * 5.5);          // wide bloom

    float3 col = float3(0.0);
    if (r > 1.0) {
        // Only the hotspots bleed past the rim.
        float k = smoothstep(1.30, 1.0, r);
        col = orange * hotBloom * 0.34 * k + float3(1.0, 0.85, 0.6) * hot * 0.6 * k;
        col *= bright;
        float a = clamp(max(max(col.r, col.g), col.b), 0.0, 1.0);
        return half4(half3(col), half(a));
    }

    // ── Glass body ──
    float zN = sqrt(max(0.0, 1.0 - r * r));
    // Soft cool reflection across the upper dome, strongest near the rim.
    float dome = pow(smoothstep(0.30, 1.0, r), 1.6) * smoothstep(0.05, 0.9, -q.y);
    col += float3(0.50, 0.60, 0.80) * dome * 0.32;
    // Faint body so the sphere reads as an object even where nothing glows.
    col += float3(0.05, 0.06, 0.09) * (0.5 + 0.5 * r);
    // Thin Fresnel rim.
    float rim = smoothstep(0.955, 0.995, r) * (1.0 - smoothstep(0.995, 1.0, r));
    col += float3(0.80, 0.88, 1.0) * rim * (0.42 + 0.28 * (-q.y) + 0.2 * hotBloom);

    // ── Liquid interface ──
    float warm = smoothstep(0.30, 0.96, abs(q.x));                       // ends run hot
    float3 lineCol = mix(cool, orange, warm);
    float w = 0.012 + 0.006 * warm;
    float core = exp(-dy * dy / (2.0 * w * w));
    float glow = exp(-abs(dy) / (0.06 + 0.06 * warm));
    col += lineCol * core * (0.85 + 1.0 * warm) * (1.0 + 0.6 * react);
    col += lineCol * glow * (0.16 + 0.42 * warm) * (1.0 + 0.8 * react);

    // Warm lobe filling one side of the wave near the rim; the side drifts.
    float side = sin(t * 0.23);
    float sd = dy * side;                                               // >0 on the lit side
    float inward = exp(-(1.0 - abs(q.x)) * 1.7);
    float lobe = smoothstep(0.0, 0.04, sd) * exp(-sd * 2.8) * inward * (0.35 + 0.65 * abs(side));
    float3 lobeCol = mix(ember, orange, exp(-(1.0 - abs(q.x)) * 2.0));
    col += lobeCol * lobe * 1.5;
    // Cool film on the other side, thin and close to the interface.
    float film = smoothstep(0.0, 0.05, -sd) * exp(-(-sd) * 5.0) * (0.35 + 0.65 * (1.0 - warm));
    col += pool * film * 0.55;

    // Rim hotspots.
    col += orange * hotBloom * 0.42 + float3(1.0, 0.85, 0.6) * hot * 0.9;

    // ── Bottom pool ──
    float bottom = smoothstep(0.45, 1.0, q.y) * (1.0 - smoothstep(0.90, 1.0, r));
    col += pool * bottom * (0.42 + 0.40 * smoothstep(0.6, 0.98, r));
    float2 bp = q - float2(0.0, 0.965);
    col += float3(0.85, 0.92, 1.0) * exp(-dot(bp, bp) * 110.0) * 0.9;

    col *= bright;
    col = col / (1.0 + col * 0.25);                                     // gentle tonemap
    float alpha = clamp(max(max(col.r, col.g), col.b) * 1.15 + 0.10, 0.0, 1.0);
    alpha *= smoothstep(1.0, 0.992, r);                                 // AA edge
    return half4(half3(col * alpha), half(alpha));
}

// Setup-only glass orb. Broad refracted liquid light moves inside a crisp shell.
// Breathing repeats every 9.6 seconds; the full flow repeats every 38.4 seconds.
// RGB is interior light; the fourth channel is warm light reaching the glass.
static float4 setupLiquidLight(float2 q, float drift, float aa) {
    float3 light = float3(0.0);
    float warmLight = 0.0;
    float r = length(q);
    for (int i = 0; i < 2; ++i) {
        float seed = float(i) * 2.4;
        float turn = (i == 0 ? drift : -drift) + seed
            - 0.4 * sin(2.0 * drift + seed);
        float2 local = float2(q.x * cos(turn) + q.y * sin(turn),
                             -q.x * sin(turn) + q.y * cos(turn));
        float u = local.x - 0.24 * sin(3.0 * drift + seed);
        float bend = 0.24 * sin(2.8 * u + 5.0 * drift + seed)
            + 0.18 * sin(3.0 * drift + seed);
        float v = local.y - bend;
        float opening = 0.5 + 0.5 * sin(2.0 * u - 4.0 * drift + seed);
        float width = 0.13 + 0.19 * opening;
        float envelope = exp(-pow(u / 0.91, 6.0));
        // One defined liquid boundary with depth fading into its broad body.
        // The surface itself carries the color; no luminous outline is drawn.
        float surface = smoothstep(-width - 0.018, -width + 0.018, v);
        float thickness = exp(-pow(max(v + width, 0.0) / (width * 1.45), 1.5));
        float body = surface * thickness * envelope;
        // Reflections occupy short patches on broad liquid surfaces. There is
        // no continuous bright contour connecting two points on the rim.
        float glintAt = 0.36 * sin(2.0 * drift + seed + 0.8);
        float glint = exp(-pow((v + width * 0.88) / (0.014 + aa * 0.5), 2.0))
            * exp(-pow((u - glintAt) / 0.16, 2.0));
        float depth = i == 0 ? 1.0 : 0.20;
        float warm = smoothstep(0.48, 0.93, r)
            * (0.20 + 0.80 * smoothstep(-0.10, 0.55, u));
        float3 tint = mix(float3(0.035, 0.24, 0.80), float3(1.0, 0.37, 0.07), warm);
        light += tint * body * depth * 0.74;
        light += float3(0.58, 0.80, 1.0) * body * opening * depth * 0.10;
        light += float3(0.80, 0.93, 1.0) * glint * depth * 0.34;
        warmLight += body * warm * depth;
    }
    return float4(light, warmLight);
}

[[ stitchable ]] half4 setupOrb(float2 pos, half4 inColor, float2 size, float t) {
    // Match the setup screen's existing visible diameter (53% of its slot).
    float phase = t * (2.0 * M_PI_F / 9.6);
    float breathe = 1.0 + 0.035 * sin(phase) - 0.012 * sin(2.0 * phase);
    float radius = min(size.x, size.y) * 0.265 * breathe;
    float2 q = (pos - size * 0.5) / radius;
    // Inverse-warp the glass and its liquid together so reflections stay
    // attached as the idle silhouette softly pulses.
    float angle = dot(q, q) > 0.00001 ? atan2(q.y, q.x) : 0.0;
    float flex = 0.022 * sin(3.0 * angle + phase)
        + 0.012 * sin(2.0 * angle - 2.0 * phase);
    q /= 1.0 + flex * smoothstep(0.1, 0.9, length(q));
    float r = length(q);
    if (r > 1.22) { return half4(0.0); }

    float drift = t * (2.0 * M_PI_F / 38.4);
    float aa = 1.0 / radius;
    float4 liquid = setupLiquidLight(q, drift, aa);
    float3 ice = float3(0.55, 0.77, 1.0);
    float3 pearl = float3(0.88, 0.96, 1.0);
    float3 blue = float3(0.045, 0.30, 0.82);
    // Warm light only blooms where a liquid surface reaches the glass.
    float contact = exp(-pow((r - 0.99) / 0.048, 2.0));
    float3 glow = float3(1.0, 0.57, 0.20) * liquid.a * contact * 0.34;
    float coverage = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, r);

    // A transparent exterior lets the page's aurora show through the bloom.
    float glowAlpha = clamp(max(glow.r, max(glow.g, glow.b)), 0.0, 1.0);
    float outerFade = 1.0 - smoothstep(1.02, 1.22, r);
    float3 exterior = glow * outerFade;
    float exteriorAlpha = glowAlpha * outerFade;
    if (r > 1.0 + aa) { return half4(half3(exterior), half(exteriorAlpha)); }

    float3 col = float3(0.002, 0.005, 0.009);
    float interiorMask = 1.0 - smoothstep(0.58, 0.91, r);
    // Motes follow tilted 3D orbits: depth changes their focus and brightness,
    // making them feel suspended inside the sphere instead of stuck on top.
    for (int i = 0; i < 7; ++i) {
        float seed = float(i) * 2.39996;
        float orbit = 0.30 + 0.045 * float(i);
        float theta = drift + seed;
        float3 p = float3(orbit * cos(theta), 0.18 * sin(seed), orbit * sin(theta));
        float2 mote = float2(p.x, p.y * 0.82 - p.z * 0.57);
        float depth = 0.5 + 0.5 * (p.y * 0.57 + p.z * 0.82) / 0.7;
        float d2 = dot(q - mote, q - mote);
        float focus = max(mix(0.011, 0.0045, depth), aa * 0.5);
        float light = exp(-d2 / (focus * focus)) * (0.24 + 0.55 * depth)
            + exp(-d2 / 0.0014) * 0.018;
        col += mix(ice, pearl, depth) * light * interiorMask;
    }
    float bowl = sqrt(max(0.0, 1.0 - q.x * q.x));
    // Curved reflections with a narrow specular highlight over a blue body.
    float capY = -0.80 * bowl - 0.075;
    float cap = exp(-pow((q.y - capY) / 0.075, 2.0));
    float capFalloff = exp(-pow(q.x / 0.82, 4.0));
    float keyLight = 0.68 + 0.32 * exp(-pow((q.x + 0.25) / 0.55, 2.0));
    col += ice * cap * capFalloff * keyLight * 0.88;
    col += pearl * exp(-pow((q.y - capY + 0.015) / 0.017, 2.0))
        * exp(-pow((q.x + 0.22) / 0.48, 2.0)) * 0.46;
    col += blue * exp(-pow((q.y - capY) / 0.15, 2.0)) * capFalloff * 0.07;
    float bottomY = 0.89 * bowl + 0.025;
    float bottom = exp(-pow((q.y - bottomY) / 0.060, 2.0));
    col += ice * bottom * exp(-pow(q.x / 0.78, 4.0)) * 0.76;
    col += pearl * exp(-pow((q.y - bottomY) / 0.014, 2.0))
        * exp(-pow(q.x / 0.34, 2.0)) * 0.52;
    col += blue * exp(-pow((q.y - bottomY) / 0.14, 2.0)) * 0.07;
    // A crisp Fresnel edge, strongest where the glass catches the key light.
    float rim = exp(-pow((r - 0.991) / (0.005 + aa * 0.45), 2.0));
    col += ice * rim * (0.18 + 0.30 * abs(q.y));

    col += liquid.rgb;
    col += glow;

    // Preserve the near-black glass interior and return premultiplied alpha.
    col = min(col, float3(1.0));
    float alpha = mix(exteriorAlpha, 1.0, coverage);
    float3 result = mix(exterior, col, coverage);
    return half4(half3(min(result, float3(alpha))), half(alpha));
}
