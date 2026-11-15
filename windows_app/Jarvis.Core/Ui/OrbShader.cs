namespace Jarvis.Core.Ui;

/// The Jarvis orb's pixels: a line-for-line port of `setupOrb` in the Mac/iPhone OrbShader.metal
/// (a crisp glass shell with broad liquid light inside, slow motes, a warm bloom where the liquid
/// meets the glass). The island draws it on the GPU (Jarvis/Orb/OrbShader.hlsl is the same code);
/// this copy renders the still frame when the GPU path isn't there, and keeps the maths tested.
public static class OrbShader
{
    private const float Pi = MathF.PI;

    /// Premultiplied RGBA (0…1) at `pos` (pixels, y down) on a square surface `size` pixels wide.
    public static (float R, float G, float B, float A) SetupOrb(float px, float py, float size, float t)
    {
        var phase = t * (2f * Pi / 9.6f);
        var breathe = 1f + 0.035f * MathF.Sin(phase) - 0.012f * MathF.Sin(2f * phase);
        var radius = size * 0.265f * breathe;
        var qx = (px - size * 0.5f) / radius;
        var qy = (py - size * 0.5f) / radius;
        var angle = qx * qx + qy * qy > 0.00001f ? MathF.Atan2(qy, qx) : 0f;
        var flex = 0.022f * MathF.Sin(3f * angle + phase) + 0.012f * MathF.Sin(2f * angle - 2f * phase);
        var warp = 1f + flex * Smoothstep(0.1f, 0.9f, Len(qx, qy));
        qx /= warp;
        qy /= warp;
        var r = Len(qx, qy);
        if (r > 1.22f) return (0, 0, 0, 0);

        var drift = t * (2f * Pi / 38.4f);
        var aa = 1f / radius;
        var (lr, lg, lb, la) = LiquidLight(qx, qy, drift, aa);
        var contact = MathF.Exp(-Sq((r - 0.99f) / 0.048f));
        var gr = 1.0f * la * contact * 0.34f;
        var gg = 0.57f * la * contact * 0.34f;
        var gb = 0.20f * la * contact * 0.34f;
        var coverage = 1f - Smoothstep(1f - aa, 1f + aa, r);

        var glowAlpha = Math.Clamp(MathF.Max(gr, MathF.Max(gg, gb)), 0f, 1f);
        var outerFade = 1f - Smoothstep(1.02f, 1.22f, r);
        var er = gr * outerFade;
        var eg = gg * outerFade;
        var eb = gb * outerFade;
        var exteriorAlpha = glowAlpha * outerFade;
        if (r > 1f + aa) return (er, eg, eb, exteriorAlpha);

        float cr = 0.002f, cg = 0.005f, cb = 0.009f;
        var interiorMask = 1f - Smoothstep(0.58f, 0.91f, r);
        for (var i = 0; i < 7; i++)
        {
            var seed = i * 2.39996f;
            var orbit = 0.30f + 0.045f * i;
            var theta = drift + seed;
            var p1 = orbit * MathF.Cos(theta);
            var p2 = 0.18f * MathF.Sin(seed);
            var p3 = orbit * MathF.Sin(theta);
            var mx = p1;
            var my = p2 * 0.82f - p3 * 0.57f;
            var depth = 0.5f + 0.5f * (p2 * 0.57f + p3 * 0.82f) / 0.7f;
            var d2 = Sq(qx - mx) + Sq(qy - my);
            var focus = MathF.Max(Mix(0.011f, 0.0045f, depth), aa * 0.5f);
            var light = MathF.Exp(-d2 / (focus * focus)) * (0.24f + 0.55f * depth) + MathF.Exp(-d2 / 0.0014f) * 0.018f;
            cr += Mix(0.55f, 0.88f, depth) * light * interiorMask;
            cg += Mix(0.77f, 0.96f, depth) * light * interiorMask;
            cb += Mix(1.0f, 1.0f, depth) * light * interiorMask;
        }
        var bowl = MathF.Sqrt(MathF.Max(0f, 1f - qx * qx));
        var capY = -0.80f * bowl - 0.075f;
        var cap = MathF.Exp(-Sq((qy - capY) / 0.075f));
        var capFalloff = MathF.Exp(-Sq(Sq(qx / 0.82f)));
        var keyLight = 0.68f + 0.32f * MathF.Exp(-Sq((qx + 0.25f) / 0.55f));
        var k1 = cap * capFalloff * keyLight * 0.88f;
        var k2 = MathF.Exp(-Sq((qy - capY + 0.015f) / 0.017f)) * MathF.Exp(-Sq((qx + 0.22f) / 0.48f)) * 0.46f;
        var k3 = MathF.Exp(-Sq((qy - capY) / 0.15f)) * capFalloff * 0.07f;
        var bottomY = 0.89f * bowl + 0.025f;
        var bottom = MathF.Exp(-Sq((qy - bottomY) / 0.060f));
        var k4 = bottom * MathF.Exp(-Sq(Sq(qx / 0.78f))) * 0.76f;
        var k5 = MathF.Exp(-Sq((qy - bottomY) / 0.014f)) * MathF.Exp(-Sq(qx / 0.34f)) * 0.52f;
        var k6 = MathF.Exp(-Sq((qy - bottomY) / 0.14f)) * 0.07f;
        var rim = MathF.Exp(-Sq((r - 0.991f) / (0.005f + aa * 0.45f)));
        var k7 = rim * (0.18f + 0.30f * MathF.Abs(qy));
        // ice (0.55, 0.77, 1.0) · pearl (0.88, 0.96, 1.0) · blue (0.045, 0.30, 0.82)
        cr += 0.55f * (k1 + k4 + k7) + 0.88f * (k2 + k5) + 0.045f * (k3 + k6);
        cg += 0.77f * (k1 + k4 + k7) + 0.96f * (k2 + k5) + 0.30f * (k3 + k6);
        cb += 1.0f * (k1 + k4 + k7) + 1.0f * (k2 + k5) + 0.82f * (k3 + k6);

        cr = MathF.Min(cr + lr + gr, 1f);
        cg = MathF.Min(cg + lg + gg, 1f);
        cb = MathF.Min(cb + lb + gb, 1f);
        var alpha = Mix(exteriorAlpha, 1f, coverage);
        return (MathF.Min(Mix(er, cr, coverage), alpha), MathF.Min(Mix(eg, cg, coverage), alpha),
            MathF.Min(Mix(eb, cb, coverage), alpha), alpha);
    }

    private static (float R, float G, float B, float Warm) LiquidLight(float qx, float qy, float drift, float aa)
    {
        float lr = 0, lg = 0, lb = 0, warmLight = 0;
        var r = Len(qx, qy);
        for (var i = 0; i < 2; i++)
        {
            var seed = i * 2.4f;
            var turn = (i == 0 ? drift : -drift) + seed - 0.4f * MathF.Sin(2f * drift + seed);
            var c = MathF.Cos(turn);
            var s = MathF.Sin(turn);
            var lx = qx * c + qy * s;
            var ly = -qx * s + qy * c;
            var u = lx - 0.24f * MathF.Sin(3f * drift + seed);
            var bend = 0.24f * MathF.Sin(2.8f * u + 5f * drift + seed) + 0.18f * MathF.Sin(3f * drift + seed);
            var v = ly - bend;
            var opening = 0.5f + 0.5f * MathF.Sin(2f * u - 4f * drift + seed);
            var width = 0.13f + 0.19f * opening;
            var e2 = Sq(u / 0.91f);
            var envelope = MathF.Exp(-(e2 * e2 * e2));
            var surface = Smoothstep(-width - 0.018f, -width + 0.018f, v);
            var thickness = MathF.Exp(-MathF.Pow(MathF.Max(v + width, 0f) / (width * 1.45f), 1.5f));
            var body = surface * thickness * envelope;
            var glintAt = 0.36f * MathF.Sin(2f * drift + seed + 0.8f);
            var glint = MathF.Exp(-Sq((v + width * 0.88f) / (0.014f + aa * 0.5f))) * MathF.Exp(-Sq((u - glintAt) / 0.16f));
            var depth = i == 0 ? 1f : 0.20f;
            var warm = Smoothstep(0.48f, 0.93f, r) * (0.20f + 0.80f * Smoothstep(-0.10f, 0.55f, u));
            lr += Mix(0.035f, 1.0f, warm) * body * depth * 0.74f + 0.58f * body * opening * depth * 0.10f + 0.80f * glint * depth * 0.34f;
            lg += Mix(0.24f, 0.37f, warm) * body * depth * 0.74f + 0.80f * body * opening * depth * 0.10f + 0.93f * glint * depth * 0.34f;
            lb += Mix(0.80f, 0.07f, warm) * body * depth * 0.74f + 1.0f * body * opening * depth * 0.10f + 1.0f * glint * depth * 0.34f;
            warmLight += body * warm * depth;
        }
        return (lr, lg, lb, warmLight);
    }

    /// A whole frame as premultiplied BGRA bytes (row-major, `side` × `side`): the still frame.
    public static byte[] RenderBgra(int side, float t)
    {
        var px = new byte[side * side * 4];
        for (var y = 0; y < side; y++)
        for (var x = 0; x < side; x++)
        {
            var (r, g, b, a) = SetupOrb(x + 0.5f, y + 0.5f, side, t);
            var i = (y * side + x) * 4;
            px[i] = ToByte(b);
            px[i + 1] = ToByte(g);
            px[i + 2] = ToByte(r);
            px[i + 3] = ToByte(a);
        }
        return px;
    }

    private static byte ToByte(float v) => (byte)Math.Clamp((int)MathF.Round(v * 255f), 0, 255);
    private static float Sq(float v) => v * v;
    private static float Len(float x, float y) => MathF.Sqrt(x * x + y * y);
    private static float Mix(float a, float b, float t) => a + (b - a) * t;

    private static float Smoothstep(float e0, float e1, float x)
    {
        var t = Math.Clamp((x - e0) / (e1 - e0), 0f, 1f);
        return t * t * (3f - 2f * t);
    }
}
