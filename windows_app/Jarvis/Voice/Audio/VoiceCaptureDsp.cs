using System.Runtime.InteropServices;
using Jarvis.Core.Voice;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace Jarvis.Voice.Audio;

/// Echo-cancelled mic through the Windows Voice Capture DSP (CLSID_CWMAudioAEC) in source mode:
/// it captures the mic itself and subtracts what the chosen speaker is playing, which is what
/// keeps Jarvis from hearing its own reply on speakers. Built into Windows (nothing to ship),
/// works for speakers and headsets. Output: 16 kHz mono PCM16, pulled every 10 ms on its own
/// thread, emitted as 10 ms frames. Re-created on every Start, so a device change takes the new
/// device indexes (an old instance would keep listening to a mic that went silent).
public sealed class VoiceCaptureDsp : IAecCapture, IDisposable
{
    private static readonly Guid ClsidAec = new("745057c7-f353-4f2d-a7ee-58434477730e");
    private static readonly Guid AecProps = new("6f52c567-0360-4bd2-9617-ccbf1421c939");
    private const int PidSystemMode = 2, PidSourceMode = 3, PidDeviceIndexes = 4;
    private const int SingleChannelAec = 0;
    private const int FrameSamples = 160;
    private const uint Incomplete = 0x01000000;

    private Thread? _thread;
    private volatile bool _running;

    public event Action<ReadOnlyMemory<short>>? Frame;
    public event Action<string>? Log;

    public void Start(string renderId, string captureId)
    {
        Stop();
        DuckingOptOut.Apply(Log);
        var render = AudioEndpoints.IndexOf(renderId, DataFlow.Render);
        var capture = AudioEndpoints.IndexOf(captureId, DataFlow.Capture);
        _running = true;
        _thread = new Thread(() => Run(render, capture)) { IsBackground = true, Name = "jarvis-aec", Priority = ThreadPriority.AboveNormal };
        _thread.SetApartmentState(ApartmentState.MTA);
        _thread.Start();
    }

    public void Stop()
    {
        _running = false;
        _thread?.Join(500);
        _thread = null;
    }

    private void Run(int render, int capture)
    {
        object? com = null;
        IDmo? dmo = null;
        var format = IntPtr.Zero;
        using var buffer = new DmoBuffer(16000 * 2);
        var bufferPtr = IntPtr.Zero;
        try
        {
            var type = Type.GetTypeFromCLSID(ClsidAec, throwOnError: true)!;
            com = Activator.CreateInstance(type)!;
            var props = (IAecPropertyStore)com;
            SetInt(props, PidSystemMode, SingleChannelAec);
            SetBool(props, PidSourceMode, true);
            SetInt(props, PidDeviceIndexes, (render << 16) | (capture & 0xFFFF));

            dmo = (IDmo)com;
            format = Marshal.AllocCoTaskMem(18);
            WriteWaveFormat(format);
            var mt = new DmoMediaType
            {
                majortype = new Guid("73647561-0000-0010-8000-00AA00389B71"),   // MEDIATYPE_Audio
                subtype = new Guid("00000001-0000-0010-8000-00AA00389B71"),     // MEDIASUBTYPE_PCM
                bFixedSizeSamples = 1,
                lSampleSize = 2,
                formattype = new Guid("05589f81-c356-11ce-bf01-00aa0055595a"),  // FORMAT_WaveFormatEx
                cbFormat = 18,
                pbFormat = format,
            };
            Check(dmo.SetOutputType(0, ref mt, 0), "SetOutputType");
            Check(dmo.AllocateStreamingResources(), "AllocateStreamingResources");

            bufferPtr = Marshal.GetComInterfaceForObject(buffer, typeof(IDmoMediaBuffer));
            var outputs = new DmoOutputDataBuffer[1];
            var pending = new List<short>(FrameSamples * 4);
            while (_running)
            {
                while (_running)
                {
                    buffer.Reset();
                    outputs[0] = new DmoOutputDataBuffer { pBuffer = bufferPtr };
                    var hr = dmo.ProcessOutput(0, 1, outputs, out _);
                    if (hr < 0) break;
                    var data = buffer.Take();
                    for (var i = 0; i + 1 < data.Length; i += 2) pending.Add((short)(data[i] | (data[i + 1] << 8)));
                    while (pending.Count >= FrameSamples)
                    {
                        var frame = pending.GetRange(0, FrameSamples).ToArray();
                        pending.RemoveRange(0, FrameSamples);
                        Frame?.Invoke(frame);
                    }
                    if ((outputs[0].dwStatus & Incomplete) == 0 || data.Length == 0) break;
                }
                Thread.Sleep(10);
            }
        }
        catch (Exception e) when (e is COMException or InvalidCastException or InvalidOperationException or ArgumentException)
        {
            Log?.Invoke($"aec capture failed: {e.Message}");
        }
        finally
        {
            if (dmo != null) dmo.FreeStreamingResources();
            if (bufferPtr != IntPtr.Zero) Marshal.Release(bufferPtr);
            if (format != IntPtr.Zero) Marshal.FreeCoTaskMem(format);
            if (com != null && Marshal.IsComObject(com)) Marshal.ReleaseComObject(com);
        }
    }

    private static void Check(int hr, string what)
    {
        if (hr < 0) throw new COMException($"{what} failed", hr);
    }

    private static void WriteWaveFormat(IntPtr p)
    {
        Marshal.WriteInt16(p, 0, 1);          // WAVE_FORMAT_PCM
        Marshal.WriteInt16(p, 2, 1);          // mono
        Marshal.WriteInt32(p, 4, 16000);      // samples/s
        Marshal.WriteInt32(p, 8, 32000);      // bytes/s
        Marshal.WriteInt16(p, 12, 2);         // block align
        Marshal.WriteInt16(p, 14, 16);        // bits
        Marshal.WriteInt16(p, 16, 0);         // cbSize
    }

    private static void SetInt(IAecPropertyStore props, int pid, int value)
    {
        var key = new PropertyKey(AecProps, pid);
        var v = new PropVariant { vt = (short)VarEnum.VT_I4, intVal = value };
        props.SetValue(ref key, ref v);
    }

    private static void SetBool(IAecPropertyStore props, int pid, bool value)
    {
        var key = new PropertyKey(AecProps, pid);
        var v = new PropVariant { vt = (short)VarEnum.VT_BOOL, boolVal = (short)(value ? -1 : 0) };
        props.SetValue(ref key, ref v);
    }

    public void Dispose() => Stop();
}

[StructLayout(LayoutKind.Sequential)]
internal struct DmoMediaType
{
    public Guid majortype;
    public Guid subtype;
    public int bFixedSizeSamples;
    public int bTemporalCompression;
    public uint lSampleSize;
    public Guid formattype;
    public IntPtr pUnk;
    public uint cbFormat;
    public IntPtr pbFormat;
}

[StructLayout(LayoutKind.Sequential)]
internal struct DmoOutputDataBuffer
{
    public IntPtr pBuffer;
    public uint dwStatus;
    public long rtTimestamp;
    public long rtTimelength;
}

/// IMediaObject, declared in vtable order (only the calls used are typed).
[ComImport, Guid("d8ad0f58-5494-4102-97c5-ec798e59bcf4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IDmo
{
    [PreserveSig] int GetStreamCount(out int inputs, out int outputs);
    [PreserveSig] int GetInputStreamInfo(int stream, out int flags);
    [PreserveSig] int GetOutputStreamInfo(int stream, out int flags);
    [PreserveSig] int GetInputType(int stream, int index, IntPtr mt);
    [PreserveSig] int GetOutputType(int stream, int index, IntPtr mt);
    [PreserveSig] int SetInputType(int stream, IntPtr mt, int flags);
    [PreserveSig] int SetOutputType(int stream, ref DmoMediaType mt, int flags);
    [PreserveSig] int GetInputCurrentType(int stream, IntPtr mt);
    [PreserveSig] int GetOutputCurrentType(int stream, IntPtr mt);
    [PreserveSig] int GetInputSizeInfo(int stream, out int size, out int lookahead, out int align);
    [PreserveSig] int GetOutputSizeInfo(int stream, out int size, out int align);
    [PreserveSig] int GetInputMaxLatency(int stream, out long latency);
    [PreserveSig] int SetInputMaxLatency(int stream, long latency);
    [PreserveSig] int Flush();
    [PreserveSig] int Discontinuity(int stream);
    [PreserveSig] int AllocateStreamingResources();
    [PreserveSig] int FreeStreamingResources();
    [PreserveSig] int GetInputStatus(int stream, out int flags);
    [PreserveSig] int ProcessInput(int stream, IntPtr buffer, int flags, long time, long length);
    [PreserveSig] int ProcessOutput(int flags, int count, [In, Out] DmoOutputDataBuffer[] buffers, out int status);
    [PreserveSig] int Lock(int lockIt);
}

[ComImport, Guid("59eff8b9-938c-4a26-82f2-95cb84cdc837"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IDmoMediaBuffer
{
    [PreserveSig] int SetLength(int length);
    [PreserveSig] int GetMaxLength(out int max);
    [PreserveSig] int GetBufferAndLength(IntPtr ppBuffer, IntPtr pcbLength);
}

/// The output buffer the DSP writes into (unmanaged memory, handed out as IMediaBuffer).
[ComVisible(true)]
internal sealed class DmoBuffer : IDmoMediaBuffer, IDisposable
{
    private readonly IntPtr _data;
    private readonly int _max;
    private int _length;

    public DmoBuffer(int max)
    {
        _max = max;
        _data = Marshal.AllocHGlobal(max);
    }

    public void Reset() => _length = 0;

    public byte[] Take()
    {
        var bytes = new byte[_length];
        if (_length > 0) Marshal.Copy(_data, bytes, 0, _length);
        _length = 0;
        return bytes;
    }

    public int SetLength(int length)
    {
        if (length > _max) return unchecked((int)0x80070057);   // E_INVALIDARG
        _length = length;
        return 0;
    }

    public int GetMaxLength(out int max)
    {
        max = _max;
        return 0;
    }

    public int GetBufferAndLength(IntPtr ppBuffer, IntPtr pcbLength)
    {
        if (ppBuffer != IntPtr.Zero) Marshal.WriteIntPtr(ppBuffer, _data);
        if (pcbLength != IntPtr.Zero) Marshal.WriteInt32(pcbLength, _length);
        return 0;
    }

    public void Dispose() => Marshal.FreeHGlobal(_data);
}

/// IPropertyStore (NAudio keeps its own internal): the DSP's settings live here.
[ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAecPropertyStore
{
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int GetAt(int index, out PropertyKey key);
    [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
    [PreserveSig] int Commit();
}
