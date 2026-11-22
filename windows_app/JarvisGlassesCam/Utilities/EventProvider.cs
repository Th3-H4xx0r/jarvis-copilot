// Jarvis Glasses camera: adapted from VCamNetSample (https://github.com/smourier/VCamNetSample).
// Copyright (c) 2024-2026 Simon Mourier. MIT License; the full notice is in THIRD_PARTY_NOTICES.md.
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using DirectN;
using Jarvis.Core.GlassesCamera;

namespace JarvisGlassesCam.Utilities
{
    /// Traces from inside Windows' camera service (and every other process that loads the source).
    /// Everything goes to ETW in string-only mode (provider 0a2f434e-b285-4240-a145-8111ff08531d;
    /// read it with TraceSpy or `logman`); errors and the stream's life also go to a small log
    /// file next to the frame file (source.log), readable over SSH without any tool.
    public sealed class EventProvider : ILogger, IDisposable
    {
        public static Guid DefaultProviderId { get; } = new Guid("0a2f434e-b285-4240-a145-8111ff08531d");

        public static EventProvider? Current => _current.Value;
        private static readonly Lazy<EventProvider?> _current = new(() =>
        {
            try { return new EventProvider(DefaultProviderId); }
            catch (Win32Exception) { return null; }
        });

        private static readonly object FileLock = new();
        private const long MaxFileBytes = 256 * 1024;

        private long _handle;
        public Guid Id { get; }

        public EventProvider(Guid id)
        {
            Id = id;
            var hr = EventRegister(id, IntPtr.Zero, IntPtr.Zero, out _handle);
            if (hr != 0)
                throw new Win32Exception(hr);
        }

        public bool WriteMessageEvent(string? text, byte level = 0, long keywords = 0) => EventWriteString(_handle, level, keywords, text) == 0;

        public void Dispose()
        {
            var handle = Interlocked.Exchange(ref _handle, 0);
            if (handle != 0)
            {
                _ = EventUnregister(handle);
            }
        }

        void ILogger.Log(TraceLevel level, string message, string methodName) => Log(level, message, methodName, null);
        public static void LogError(string? message = null, [CallerMemberName] string? methodName = null, [CallerFilePath] string? filePath = null)
        {
            Log(TraceLevel.Error, message, methodName, filePath);
            Note($"error in {Name(filePath)}::{methodName}: {message}");
        }
        public static void LogWarning(string? message = null, [CallerMemberName] string? methodName = null, [CallerFilePath] string? filePath = null) => Log(TraceLevel.Warning, message, methodName, filePath);
        public static void LogInfo(string? message = null, [CallerMemberName] string? methodName = null, [CallerFilePath] string? filePath = null) => Log(TraceLevel.Info, message, methodName, filePath);
        public static void LogVerbose(string? message = null, [CallerMemberName] string? methodName = null, [CallerFilePath] string? filePath = null) => Log(TraceLevel.Verbose, message, methodName, filePath);
        public static void Log(TraceLevel level, string? message = null, [CallerMemberName] string? methodName = null, [CallerFilePath] string? filePath = null)
        {
            var current = Current;
            if (current == null)
                return;

            current.WriteMessageEvent($"[{Environment.CurrentManagedThreadId}]{Name(filePath)}::{methodName}:{message}", (byte)level);
        }

        private static string? Name(string? filePath) => filePath != null ? Path.GetFileNameWithoutExtension(filePath) : null;

        /// One line in source.log (the stream's start/stop, errors). Best effort: never throws.
        public static void Note(string line)
        {
            try
            {
                var path = Path.Combine(GlassesCamSpec.DataDir, "source.log");
                lock (FileLock)
                {
                    var info = new FileInfo(path);
                    if (info.Exists && info.Length > MaxFileBytes) File.Move(path, path + ".old", overwrite: true);
                    File.AppendAllText(path, $"{DateTime.UtcNow:O} [{Environment.ProcessId} {Process.GetCurrentProcess().ProcessName}] {line}{Environment.NewLine}");
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
        }

        [DllImport("advapi32")]
        private static extern int EventRegister([MarshalAs(UnmanagedType.LPStruct)] Guid ProviderId, IntPtr EnableCallback, IntPtr CallbackContext, out long RegHandle);

        [DllImport("advapi32")]
        private static extern int EventUnregister(long RegHandle);

        [DllImport("advapi32")]
        private static extern int EventWriteString(long RegHandle, byte Level, long Keyword, [MarshalAs(UnmanagedType.LPWStr)] string? String);
    }
}
