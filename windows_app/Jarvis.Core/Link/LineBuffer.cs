using System.Text.Json;
using System.Text.Json.Nodes;

namespace Jarvis.Core.Link;

public sealed class LineTooLongException : Exception
{
    public LineTooLongException() : base("a line from jc-client went past 1 MiB without a newline") { }
}

/// Splits the newline-JSON byte stream into objects. Bad JSON and non-objects are skipped.
public sealed class LineBuffer
{
    public const int MaxLine = 1_048_576;

    private byte[] _buf = new byte[4096];
    private int _len;

    public IReadOnlyList<JsonObject> Push(ReadOnlySpan<byte> chunk)
    {
        var output = new List<JsonObject>();
        // Append, then cut complete lines.
        Ensure(_len + chunk.Length);
        chunk.CopyTo(_buf.AsSpan(_len));
        _len += chunk.Length;
        var start = 0;
        while (true)
        {
            var nl = Array.IndexOf(_buf, (byte)'\n', start, _len - start);
            if (nl < 0) break;
            var line = _buf.AsSpan(start, nl - start);
            start = nl + 1;
            if (line.IsEmpty) continue;
            try
            {
                if (JsonNode.Parse(line) is JsonObject o) output.Add(o);
            }
            catch (JsonException) { }
        }
        if (start > 0)
        {
            Buffer.BlockCopy(_buf, start, _buf, 0, _len - start);
            _len -= start;
        }
        if (_len > MaxLine)
        {
            _len = 0;
            throw new LineTooLongException();
        }
        return output;
    }

    private void Ensure(int size)
    {
        if (size <= _buf.Length) return;
        var next = _buf.Length;
        while (next < size) next *= 2;
        Array.Resize(ref _buf, next);
    }
}
