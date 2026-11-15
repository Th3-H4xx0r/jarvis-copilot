// The Jarvis orb (ps_3_0, a WPF ShaderEffect): a line-for-line port of `setupOrb` in
// mac_app/Sources/JarvisVoiceUI/Voice/Views/OrbShader.metal — the same shader the Mac island,
// the Mac voice panel and the iPhone draw. Jarvis.Core/Ui/OrbShader.cs is the CPU copy (still
// frame fallback + tests); keep the three in step.
//
// c0.x = the surface's side in device pixels; c1.x = the shader clock (seconds, wraps at 38.4).
// The surface is size / 0.53 of the visible sphere. Output is premultiplied.

sampler2D input : register(s0);
float surfaceSize : register(c0);
float clock : register(c1);

static const float PI = 3.14159265;

float sq(float v) { return v * v; }

float4 liquidLight(float2 q, float drift, float aa)
{
    float3 light = float3(0.0, 0.0, 0.0);
    float warmLight = 0.0;
    float r = length(q);
    [unroll] for (int i = 0; i < 2; ++i)
    {
        float seed = (float)i * 2.4;
        float turn = (i == 0 ? drift : -drift) + seed - 0.4 * sin(2.0 * drift + seed);
        float c = cos(turn);
        float s = sin(turn);
        float2 local = float2(q.x * c + q.y * s, -q.x * s + q.y * c);
        float u = local.x - 0.24 * sin(3.0 * drift + seed);
        float bend = 0.24 * sin(2.8 * u + 5.0 * drift + seed) + 0.18 * sin(3.0 * drift + seed);
        float v = local.y - bend;
        float opening = 0.5 + 0.5 * sin(2.0 * u - 4.0 * drift + seed);
        float width = 0.13 + 0.19 * opening;
        float e2 = sq(u / 0.91);
        float envelope = exp(-(e2 * e2 * e2));
        float surface = smoothstep(-width - 0.018, -width + 0.018, v);
        float thickness = exp(-pow(max(v + width, 0.000001) / (width * 1.45), 1.5));
        float body = surface * thickness * envelope;
        float glintAt = 0.36 * sin(2.0 * drift + seed + 0.8);
        float glint = exp(-sq((v + width * 0.88) / (0.014 + aa * 0.5))) * exp(-sq((u - glintAt) / 0.16));
        float depth = i == 0 ? 1.0 : 0.20;
        float warm = smoothstep(0.48, 0.93, r) * (0.20 + 0.80 * smoothstep(-0.10, 0.55, u));
        float3 tint = lerp(float3(0.035, 0.24, 0.80), float3(1.0, 0.37, 0.07), warm);
        light += tint * body * depth * 0.74;
        light += float3(0.58, 0.80, 1.0) * body * opening * depth * 0.10;
        light += float3(0.80, 0.93, 1.0) * glint * depth * 0.34;
        warmLight += body * warm * depth;
    }
    return float4(light, warmLight);
}

float4 main(float2 uv : TEXCOORD) : COLOR
{
    float size = surfaceSize;
    float t = clock;
    float2 pos = uv * size;
    float phase = t * (2.0 * PI / 9.6);
    float breathe = 1.0 + 0.035 * sin(phase) - 0.012 * sin(2.0 * phase);
    float radius = size * 0.265 * breathe;
    float2 q = (pos - size * 0.5) / radius;
    float angle = dot(q, q) > 0.00001 ? atan2(q.y, q.x) : 0.0;
    float flex = 0.022 * sin(3.0 * angle + phase) + 0.012 * sin(2.0 * angle - 2.0 * phase);
    q /= 1.0 + flex * smoothstep(0.1, 0.9, length(q));
    float r = length(q);
    if (r > 1.22) { return float4(0.0, 0.0, 0.0, 0.0); }

    float drift = t * (2.0 * PI / 38.4);
    float aa = 1.0 / radius;
    float4 liquid = liquidLight(q, drift, aa);
    float3 ice = float3(0.55, 0.77, 1.0);
    float3 pearl = float3(0.88, 0.96, 1.0);
    float3 blue = float3(0.045, 0.30, 0.82);
    float contact = exp(-sq((r - 0.99) / 0.048));
    float3 glow = float3(1.0, 0.57, 0.20) * liquid.a * contact * 0.34;
    float coverage = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, r);

    float glowAlpha = saturate(max(glow.r, max(glow.g, glow.b)));
    float outerFade = 1.0 - smoothstep(1.02, 1.22, r);
    float3 exterior = glow * outerFade;
    float exteriorAlpha = glowAlpha * outerFade;
    float a0 = tex2D(input, uv).a;
    if (r > 1.0 + aa) { return float4(exterior, exteriorAlpha) * a0; }

    float3 col = float3(0.002, 0.005, 0.009);
    float interiorMask = 1.0 - smoothstep(0.58, 0.91, r);
    [loop] for (int m = 0; m < 7; ++m)
    {
        float seed = (float)m * 2.39996;
        float orbit = 0.30 + 0.045 * (float)m;
        float theta = drift + seed;
        float3 p = float3(orbit * cos(theta), 0.18 * sin(seed), orbit * sin(theta));
        float2 mote = float2(p.x, p.y * 0.82 - p.z * 0.57);
        float depth = 0.5 + 0.5 * (p.y * 0.57 + p.z * 0.82) / 0.7;
        float2 dq = q - mote;
        float d2 = dot(dq, dq);
        float focus = max(lerp(0.011, 0.0045, depth), aa * 0.5);
        float light = exp(-d2 / (focus * focus)) * (0.24 + 0.55 * depth) + exp(-d2 / 0.0014) * 0.018;
        col += lerp(ice, pearl, depth) * light * interiorMask;
    }
    float bowl = sqrt(max(0.0, 1.0 - q.x * q.x));
    float capY = -0.80 * bowl - 0.075;
    float cap = exp(-sq((q.y - capY) / 0.075));
    float capFalloff = exp(-sq(sq(q.x / 0.82)));
    float keyLight = 0.68 + 0.32 * exp(-sq((q.x + 0.25) / 0.55));
    col += ice * cap * capFalloff * keyLight * 0.88;
    col += pearl * exp(-sq((q.y - capY + 0.015) / 0.017)) * exp(-sq((q.x + 0.22) / 0.48)) * 0.46;
    col += blue * exp(-sq((q.y - capY) / 0.15)) * capFalloff * 0.07;
    float bottomY = 0.89 * bowl + 0.025;
    float bottom = exp(-sq((q.y - bottomY) / 0.060));
    col += ice * bottom * exp(-sq(sq(q.x / 0.78))) * 0.76;
    col += pearl * exp(-sq((q.y - bottomY) / 0.014)) * exp(-sq(q.x / 0.34)) * 0.52;
    col += blue * exp(-sq((q.y - bottomY) / 0.14)) * 0.07;
    float rim = exp(-sq((r - 0.991) / (0.005 + aa * 0.45)));
    col += ice * rim * (0.18 + 0.30 * abs(q.y));

    col += liquid.rgb;
    col += glow;

    col = min(col, float3(1.0, 1.0, 1.0));
    float alpha = lerp(exteriorAlpha, 1.0, coverage);
    float3 result = lerp(exterior, col, coverage);
    return float4(min(result, float3(alpha, alpha, alpha)), alpha) * a0;
}
