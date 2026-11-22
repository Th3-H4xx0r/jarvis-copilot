// Jarvis Glasses camera: adapted from VCamNetSample (https://github.com/smourier/VCamNetSample).
// Copyright (c) 2024-2026 Simon Mourier. MIT License; the full notice is in THIRD_PARTY_NOTICES.md.
using System.Diagnostics;
using System.Runtime.InteropServices;
using DirectN;
using Jarvis.Core.GlassesCamera;
using JarvisGlassesCam.Utilities;

namespace JarvisGlassesCam
{
    /// The camera's one video stream: 720×1280 (the glasses' own format) and 1280×720 (the same
    /// letterboxed), each as NV12 and RGB32, 30 fps. Every sample is drawn on the CPU by
    /// FrameProvider from the newest frame the Jarvis app wrote, or the card.
    public class MediaStream : MFAttributes, IMFMediaStream2, IKsControl
    {
        public const int NUM_ALLOCATOR_SAMPLES = 10;

        private readonly object _lock = new();
        private readonly MediaSource _source;
        private IComObject<IMFMediaEventQueue>? _queue;
        private IComObject<IMFStreamDescriptor>? _descriptor;
        private IComObject<IMFVideoSampleAllocatorEx>? _allocator;
        private _MF_STREAM_STATE _state;
        private Guid _format;
        private int _width = GlassesCamSpec.Portrait.W;
        private int _height = GlassesCamSpec.Portrait.H;
        private long _frameCount;
        private FrameProvider _provider = new();
        // Pacing: requests queue their tokens; a timer hands out one sample per 1/30 s, like a real
        // camera (unpaced, a reader pulling as fast as it can would spin the camera service).
        private static readonly long FrameTicks = Stopwatch.Frequency / GlassesCamSpec.Fps;
        private readonly Queue<object?> _tokens = new();
        private Timer? _pacer;
        private bool _scheduled;
        private long _nextFrameAt;

        public MediaStream(MediaSource source, uint index)
        {
            try
            {
                ArgumentNullException.ThrowIfNull(source);
                _source = source;

                SetGUID(MFConstants.MF_DEVICESTREAM_STREAM_CATEGORY, KSMedia.PINNAME_VIDEO_CAPTURE).ThrowOnError();
                SetUINT32(MFConstants.MF_DEVICESTREAM_STREAM_ID, index).ThrowOnError();
                SetUINT32(MFConstants.MF_DEVICESTREAM_FRAMESERVER_SHARED, 1).ThrowOnError();
                SetUINT32(MFConstants.MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES, (uint)_MFFrameSourceTypes.MFFrameSourceTypes_Color).ThrowOnError();

                Functions.MFCreateEventQueue(out var queue).ThrowOnError();
                _queue = new ComObject<IMFMediaEventQueue>(queue);

                // Index 0 = the glasses' portrait format (what the Mac camera offers first); NV12 before
                // RGB32 in each size, as most apps prefer NV12.
                var mediaTypes = new List<IMFMediaType>();
                foreach (var (w, h) in GlassesCamSpec.Formats)
                {
                    mediaTypes.Add(MakeType(MFConstants.MFVideoFormat_NV12, w, h));
                    mediaTypes.Add(MakeType(MFConstants.MFVideoFormat_RGB32, w, h));
                }

                Functions.MFCreateStreamDescriptor(index, mediaTypes.Count, [.. mediaTypes], out var descriptor).ThrowOnError();
                descriptor.GetMediaTypeHandler(out var handler).ThrowOnError();
                handler.SetCurrentMediaType(mediaTypes[0]).ThrowOnError();
                _descriptor = new ComObject<IMFStreamDescriptor>(descriptor);
            }
            catch (Exception e)
            {
                EventProvider.LogError(e.ToString());
                throw;
            }
        }

        private static IMFMediaType MakeType(Guid subtype, int width, int height)
        {
            var nv12 = subtype == MFConstants.MFVideoFormat_NV12;
            Functions.MFCreateMediaType(out var type).ThrowOnError();
            type.SetGUID(MFConstants.MF_MT_MAJOR_TYPE, MFConstants.MFMediaType_Video).ThrowOnError();
            type.SetGUID(MFConstants.MF_MT_SUBTYPE, subtype).ThrowOnError();
            type.SetUINT64(MFConstants.MF_MT_FRAME_SIZE, ((ulong)width << 32) | (uint)height).ThrowOnError();
            type.SetUINT32(MFConstants.MF_MT_DEFAULT_STRIDE, (uint)(nv12 ? width : width * 4)).ThrowOnError();
            type.SetUINT32(MFConstants.MF_MT_INTERLACE_MODE, (uint)_MFVideoInterlaceMode.MFVideoInterlace_Progressive).ThrowOnError();
            type.SetUINT32(MFConstants.MF_MT_ALL_SAMPLES_INDEPENDENT, 1).ThrowOnError();
            type.SetUINT64(MFConstants.MF_MT_FRAME_RATE, ((ulong)GlassesCamSpec.Fps << 32) | 1).ThrowOnError();
            type.SetUINT64(MFConstants.MF_MT_PIXEL_ASPECT_RATIO, (1UL << 32) | 1).ThrowOnError();
            var bitrate = (long)width * height * (nv12 ? 12 : 32) * GlassesCamSpec.Fps;
            type.SetUINT32(MFConstants.MF_MT_AVG_BITRATE, (uint)Math.Min(bitrate, uint.MaxValue)).ThrowOnError();
            if (nv12)
            {
                // What FrameProvider's conversion produces (GlassesCamPixels.BgraToNv12).
                type.SetUINT32(MFConstants.MF_MT_YUV_MATRIX, (uint)_MFVideoTransferMatrix.MFVideoTransferMatrix_BT709).ThrowOnError();
                type.SetUINT32(MFConstants.MF_MT_VIDEO_NOMINAL_RANGE, (uint)_MFNominalRange.MFNominalRange_16_235).ThrowOnError();
            }
            return type;
        }

        public HRESULT Start(IMFMediaType? type)
        {
            var queue = _queue;
            var allocator = _allocator;
            if (queue == null || allocator == null)
            {
                EventProvider.LogInfo($"MF_E_SHUTDOWN");
                return HRESULTS.MF_E_SHUTDOWN;
            }

            if (type != null)
            {
                allocator.Object.InitializeSampleAllocator(NUM_ALLOCATOR_SAMPLES, type).ThrowOnError();

                type.GetGUID(MFConstants.MF_MT_SUBTYPE, out _format).ThrowOnError();
                type.GetUINT64(MFConstants.MF_MT_FRAME_SIZE, out var size).ThrowOnError();
                _width = (int)(size >> 32);
                _height = (int)(size & 0xFFFFFFFF);
                EventProvider.LogInfo($"Format: {_format.GetMFName()} {_width}x{_height}");
            }

            queue.Object.QueueEventParamVar((uint)__MIDL___MIDL_itf_mfobjects_0000_0013_0001.MEStreamStarted, Guid.Empty, HRESULTS.S_OK, null).ThrowOnError();
            if (_state != _MF_STREAM_STATE.MF_STREAM_STATE_RUNNING) _provider.Started(_width, _height, _format);
            _state = _MF_STREAM_STATE.MF_STREAM_STATE_RUNNING;
            EventProvider.LogInfo("Started");
            return HRESULTS.S_OK;
        }

        public HRESULT Stop()
        {
            var queue = _queue;
            var allocator = _allocator;
            if (queue == null || allocator == null)
            {
                EventProvider.LogInfo($"MF_E_SHUTDOWN");
                return HRESULTS.MF_E_SHUTDOWN;
            }

            allocator.Object.UninitializeSampleAllocator();
            queue.Object.QueueEventParamVar((uint)__MIDL___MIDL_itf_mfobjects_0000_0013_0001.MEStreamStopped, Guid.Empty, HRESULTS.S_OK, null).ThrowOnError();
            if (_state != _MF_STREAM_STATE.MF_STREAM_STATE_STOPPED) _provider.Stopped();
            _state = _MF_STREAM_STATE.MF_STREAM_STATE_STOPPED;
            lock (_lock)
            {
                _tokens.Clear();
                _pacer?.Change(Timeout.Infinite, Timeout.Infinite);
                _scheduled = false;
            }
            return HRESULTS.S_OK;
        }

        public static MFSampleAllocatorUsage GetAllocatorUsage() => MFSampleAllocatorUsage.MFSampleAllocatorUsage_UsesProvidedAllocator;
        public HRESULT SetAllocator(object allocator)
        {
            if (allocator == null)
            {
                EventProvider.LogInfo($"E_POINTER");
                return HRESULTS.E_POINTER;
            }

            if (allocator is not IMFVideoSampleAllocatorEx aex)
            {
                EventProvider.LogInfo($"E_NOINTERFACE");
                return HRESULTS.E_NOINTERFACE;
            }

            _allocator = new ComObject<IMFVideoSampleAllocatorEx>(aex);
            return HRESULTS.S_OK;
        }

        /// The camera always draws on the CPU into system-memory samples (VCamNetSample's "force
        /// CPU" choice): one simple path for every app, with or without Direct3D.
        public HRESULT Set3DManager(object manager)
        {
            EventProvider.LogInfo($"manager:{manager} (CPU samples kept)");
            return HRESULTS.S_OK;
        }

        //public CustomQueryInterfaceResult GetInterface(ref Guid iid, out nint ppv)
        //{
        //    EventProvider.LogInfo($"iid{iid:B}");
        //    ppv = 0;
        //    return CustomQueryInterfaceResult.NotHandled;
        //}

        public HRESULT GetEvent(uint flags, out IMFMediaEvent evt)
        {
            EventProvider.LogInfo($"flags:{flags}");
            try
            {
                lock (_lock)
                {
                    var queue = _queue;
                    if (queue == null)
                    {
                        evt = null!;
                        EventProvider.LogInfo($"MF_E_SHUTDOWN");
                        return HRESULTS.MF_E_SHUTDOWN;
                    }

                    var hr = queue.Object.GetEvent(flags, out evt);
                    EventProvider.LogInfo($" => {hr}");
                    return hr;
                }
            }
            catch (Exception e)
            {
                EventProvider.LogError(e.ToString());
                throw;
            }
        }

        public HRESULT BeginGetEvent(IMFAsyncCallback callback, object state)
        {
            //EventProvider.LogInfo($"callback:{callback} state:{state}");
            try
            {
                lock (_lock)
                {
                    var queue = _queue;
                    if (queue == null)
                    {
                        EventProvider.LogInfo($"MF_E_SHUTDOWN");
                        return HRESULTS.MF_E_SHUTDOWN;
                    }

                    var hr = queue.Object.BeginGetEvent(callback, state);
                    //EventProvider.LogInfo($" => {hr}");
                    return hr;
                }
            }
            catch (Exception e)
            {
                EventProvider.LogError(e.ToString());
                throw;
            }
        }

        public HRESULT EndGetEvent(IMFAsyncResult result, out IMFMediaEvent evt)
        {
            //EventProvider.LogInfo($"result:{result}");
            try
            {
                lock (_lock)
                {
                    var queue = _queue;
                    if (queue == null)
                    {
                        evt = null!;
                        EventProvider.LogInfo($"MF_E_SHUTDOWN");
                        return HRESULTS.MF_E_SHUTDOWN;
                    }

                    var hr = queue.Object.EndGetEvent(result, out evt);
                    //EventProvider.LogInfo($" evt {evt}=> {hr}");
                    return hr;
                }
            }
            catch (Exception e)
            {
                EventProvider.LogError(e.ToString());
                throw;
            }
        }

        public HRESULT QueueEvent(uint type, Guid extendedType, HRESULT hrStatus, PROPVARIANT value)
        {
            EventProvider.LogInfo($"type:{type} value:{value}");
            try
            {
                lock (_lock)
                {
                    var queue = _queue;
                    if (queue == null)
                    {
                        EventProvider.LogInfo($"MF_E_SHUTDOWN");
                        return HRESULTS.MF_E_SHUTDOWN;
                    }

                    var hr = queue.Object.QueueEventParamVar(type, extendedType, hrStatus, value);
                    EventProvider.LogInfo($" => {hr}");
                    return hr;
                }
            }
            catch (Exception e)
            {
                EventProvider.LogError(e.ToString());
                throw;
            }
        }

        public HRESULT GetMediaSource(out IMFMediaSource mediaSource)
        {
            EventProvider.LogInfo();
            lock (_lock)
            {
                var source = _source;
                if (source == null)
                {
                    mediaSource = null!;
                    return HRESULTS.MF_E_SHUTDOWN;
                }

                mediaSource = source;
                var hr = HRESULTS.S_OK;
                EventProvider.LogInfo($" => {hr}");
                return hr;
            }
        }

        public HRESULT GetStreamDescriptor(out IMFStreamDescriptor streamDescriptor)
        {
            EventProvider.LogInfo();
            try
            {
                lock (_lock)
                {
                    var descriptor = _descriptor;
                    if (descriptor == null)
                    {
                        streamDescriptor = null!;
                        return HRESULTS.MF_E_SHUTDOWN;
                    }

                    streamDescriptor = descriptor.Object;
                    var hr = HRESULTS.S_OK;
                    EventProvider.LogInfo($" => {hr}");
                    return hr;
                }
            }
            catch (Exception e)
            {
                EventProvider.LogError(e.ToString());
                throw;
            }
        }

        public HRESULT RequestSample(object token)
        {
            lock (_lock)
            {
                if (_allocator == null || _queue == null)
                    return HRESULTS.MF_E_SHUTDOWN;

                _tokens.Enqueue(token);
                ScheduleLocked(0);
                return HRESULTS.S_OK;
            }
        }

        private void ScheduleLocked(long extraTicks)
        {
            if (_scheduled || _tokens.Count == 0) return;
            var wait = Math.Max(extraTicks, _nextFrameAt - Stopwatch.GetTimestamp());
            _scheduled = true;
            _pacer ??= new Timer(_ => Deliver());
            _pacer.Change(TimeSpan.FromTicks(Math.Max(0, wait) * TimeSpan.TicksPerSecond / Stopwatch.Frequency), Timeout.InfiniteTimeSpan);
        }

        /// The pacer's tick: one sample for the oldest request.
        private void Deliver()
        {
            lock (_lock)
            {
                _scheduled = false;
                var queue = _queue;
                var allocator = _allocator;
                if (queue == null || allocator == null || _tokens.Count == 0) return;
                var token = _tokens.Peek();
                var hr = allocator.Object.AllocateSample(out var sample);
                if (hr == HRESULTS.MF_E_SAMPLEALLOCATOR_EMPTY)
                {
                    // The reader still holds every sample: try again shortly.
                    GC.Collect();
                    ScheduleLocked(Stopwatch.Frequency / 200);
                    return;
                }
                _tokens.Dequeue();
                try
                {
                    hr.ThrowOnError();
                    try
                    {
                        sample.SetSampleTime(Functions.MFGetSystemTime()).ThrowOnError();
                        sample.SetSampleDuration(10_000_000 / GlassesCamSpec.Fps).ThrowOnError();
                        _provider.Draw(sample, _format, _width, _height);
                        if (token != null)
                        {
                            sample.SetUnknown(MFConstants.MFSampleExtension_Token, token).ThrowOnError();
                        }

                        queue.Object.QueueEventParamUnk((uint)__MIDL___MIDL_itf_mfobjects_0000_0013_0001.MEMediaSample, Guid.Empty, HRESULTS.S_OK, sample).ThrowOnError();
                    }
                    finally
                    {
                        // The queue holds its own reference: let this one go now, so the allocator's
                        // samples come back without waiting for a collection.
                        Marshal.ReleaseComObject(sample);
                    }

                    // VCamNetSample: collect sometimes, or the allocator runs dry too early.
                    if (++_frameCount % (NUM_ALLOCATOR_SAMPLES / 2) == 0)
                    {
                        GC.Collect();
                    }
                }
                catch (Exception e)
                {
                    EventProvider.LogError(e.ToString());
                }
                var now = Stopwatch.GetTimestamp();
                _nextFrameAt = Math.Max(_nextFrameAt + FrameTicks, now);
                ScheduleLocked(0);
            }
        }

        public HRESULT SetStreamState(_MF_STREAM_STATE value)
        {
            EventProvider.LogInfo($"value:{value}");
            try
            {
                if (_state != value)
                {
                    switch (value)
                    {
                        case _MF_STREAM_STATE.MF_STREAM_STATE_STOPPED:
                            return Stop();

                        case _MF_STREAM_STATE.MF_STREAM_STATE_PAUSED:
                            if (_state != _MF_STREAM_STATE.MF_STREAM_STATE_RUNNING)
                            {
                                EventProvider.LogInfo($"MF_E_INVALID_STATE_TRANSITION");
                                return HRESULTS.MF_E_INVALID_STATE_TRANSITION;
                            }

                            _state = value;
                            break;

                        case _MF_STREAM_STATE.MF_STREAM_STATE_RUNNING:
                            return Start(null);

                        default:
                            EventProvider.LogInfo($"MF_E_INVALID_STATE_TRANSITION");
                            return HRESULTS.MF_E_INVALID_STATE_TRANSITION;
                    }
                }
                return HRESULTS.S_OK;
            }
            catch (Exception e)
            {
                EventProvider.LogError(e.ToString());
                throw;
            }
        }

        public HRESULT GetStreamState(out _MF_STREAM_STATE value)
        {
            value = _state;
            EventProvider.LogInfo($"value:{value}");
            return HRESULTS.S_OK;
        }

        public HRESULT KsProperty(ref KSIDENTIFIER roperty, uint propertyLength, nint propertyData, uint dataLength, out uint bytesReturned)
        {
            EventProvider.LogInfo($"Property:{roperty.GetMFName()} PropertyLength:{propertyLength} DataLength:{dataLength}");
            bytesReturned = 0;
            return HRESULT.FromWin32(Utilities.Constants.ERROR_SET_NOT_FOUND);
        }

        public HRESULT KsMethod(ref KSIDENTIFIER method, uint methodLength, nint methodData, uint dataLength, out uint bytesReturned)
        {
            EventProvider.LogInfo($"Method:{method.GetMFName()} PropertyLength:{methodLength} DataLength:{dataLength}");
            bytesReturned = 0;
            return HRESULT.FromWin32(Utilities.Constants.ERROR_SET_NOT_FOUND);
        }

        public HRESULT KsEvent(ref KSIDENTIFIER evt, uint eventLength, nint eventData, uint dataLength, out uint bytesReturned)
        {
            EventProvider.LogInfo($"Event:{evt.GetMFName()} PropertyLength:{eventLength} DataLength:{dataLength}");
            bytesReturned = 0;
            return HRESULT.FromWin32(Utilities.Constants.ERROR_SET_NOT_FOUND);
        }

        protected override void Dispose(bool disposing)
        {
            EventProvider.LogInfo();
            Interlocked.Exchange(ref _descriptor!, null)?.Dispose();
            Interlocked.Exchange(ref _queue!, null)?.Dispose();
            Interlocked.Exchange(ref _allocator!, null)?.Dispose();
            Interlocked.Exchange(ref _pacer, null)?.Dispose();
            Interlocked.Exchange(ref _provider!, null)?.Dispose();
            base.Dispose(disposing);
        }
    }
}
