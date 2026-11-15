using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Jarvis.Platform;

namespace Jarvis.Orb;

/// The orb shader on the GPU: OrbShader.hlsl as a WPF pixel shader (ps_3_0). It is compiled once
/// with Windows' own D3DCompiler_47.dll (in System32 since Windows 10) and the bytecode cached
/// under %LOCALAPPDATA%\Jarvis, keyed by the source's hash. Null when the machine can't run it
/// (software rendering, no ps_3_0): the orb then shows the CPU-rendered still frame.
internal sealed class OrbEffect : ShaderEffect
{
    public static readonly DependencyProperty InputProperty = RegisterPixelShaderSamplerProperty("Input", typeof(OrbEffect), 0);
    public static readonly DependencyProperty SurfaceProperty = DependencyProperty.Register(
        nameof(Surface), typeof(double), typeof(OrbEffect), new UIPropertyMetadata(100.0, PixelShaderConstantCallback(0)));
    public static readonly DependencyProperty ClockProperty = DependencyProperty.Register(
        nameof(Clock), typeof(double), typeof(OrbEffect), new UIPropertyMetadata(0.0, PixelShaderConstantCallback(1)));

    private static PixelShader? _shader;
    private static bool _tried;

    private OrbEffect(PixelShader shader)
    {
        PixelShader = shader;
        UpdateShaderValue(InputProperty);
        UpdateShaderValue(SurfaceProperty);
        UpdateShaderValue(ClockProperty);
    }

    public Brush Input { get => (Brush)GetValue(InputProperty); set => SetValue(InputProperty, value); }
    /// The surface's side in device pixels (the shader's anti-aliasing works in pixels).
    public double Surface { get => (double)GetValue(SurfaceProperty); set => SetValue(SurfaceProperty, value); }
    /// The shader clock in seconds (wraps at OrbMotion.Loop).
    public double Clock { get => (double)GetValue(ClockProperty); set => SetValue(ClockProperty, value); }

    public static OrbEffect? TryCreate() => Shader() is { } s ? new OrbEffect(s) : null;

    /// Whether the GPU path works here (logged once).
    public static bool Available => Shader() != null;

    private static PixelShader? Shader()
    {
        if (_tried) return _shader;
        _tried = true;
        try
        {
            if (!RenderCapability.IsPixelShaderVersionSupported(3, 0) || RenderCapability.Tier >> 16 < 2)
            {
                FileLog.Write("orb", "ps_3_0 not available: the still frame is used");
                return null;
            }
            var bytes = Bytecode();
            if (bytes == null) return null;
            var ps = new PixelShader();
            ps.SetStreamSource(new MemoryStream(bytes));
            ps.Freeze();
            _shader = ps;
        }
        catch (Exception e) when (e is IOException or COMException or InvalidOperationException or DllNotFoundException or EntryPointNotFoundException)
        {
            FileLog.Write("orb", $"shader unavailable: {e.Message}");
        }
        return _shader;
    }

    private static byte[]? Bytecode()
    {
        using var res = typeof(OrbEffect).Assembly.GetManifestResourceStream("Jarvis.OrbShader.hlsl");
        if (res == null) return null;
        using var reader = new StreamReader(res);
        var source = reader.ReadToEnd();
        var hash = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(source)))[..16];
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jarvis", "shaders");
        var cached = Path.Combine(dir, $"orb-{hash}.ps");
        if (File.Exists(cached)) return File.ReadAllBytes(cached);
        var bytes = Compile(source, out var error);
        if (bytes == null)
        {
            FileLog.Write("orb", $"shader compile failed: {error}");
            return null;
        }
        try
        {
            Directory.CreateDirectory(dir);
            File.WriteAllBytes(cached, bytes);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return bytes;
    }

    private const uint OptimizationLevel3 = 1u << 15;

    private static byte[]? Compile(string source, out string error)
    {
        var src = System.Text.Encoding.ASCII.GetBytes(source);
        var hr = D3DCompile(src, (UIntPtr)src.Length, "OrbShader.hlsl", IntPtr.Zero, IntPtr.Zero, "main", "ps_3_0",
            OptimizationLevel3, 0, out var code, out var errors);
        error = errors == null ? "" : Marshal.PtrToStringAnsi(errors.GetBufferPointer(), (int)errors.GetBufferSize()) ?? "";
        if (hr < 0 || code == null) return null;
        var bytes = new byte[(int)code.GetBufferSize()];
        Marshal.Copy(code.GetBufferPointer(), bytes, 0, bytes.Length);
        return bytes;
    }

    [ComImport, Guid("8BA5FB08-5195-40e2-AC58-0D989C3A0102"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ID3DBlob
    {
        [PreserveSig] IntPtr GetBufferPointer();
        [PreserveSig] UIntPtr GetBufferSize();
    }

    [DllImport("d3dcompiler_47.dll", CharSet = CharSet.Ansi, BestFitMapping = false)]
    private static extern int D3DCompile(byte[] src, UIntPtr srcLength, string sourceName, IntPtr defines, IntPtr include,
        string entryPoint, string target, uint flags1, uint flags2, out ID3DBlob? code, out ID3DBlob? errors);
}
