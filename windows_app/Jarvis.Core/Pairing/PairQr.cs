using Net.Codecrete.QrCodeGenerator;

namespace Jarvis.Core.Pairing;

/// A QR symbol as a grid of modules, row by row (true = dark). The quiet zone around it is the
/// window's (it draws the code on a white card).
public sealed record QrMatrix(int Size, bool[] Modules)
{
    public bool Dark(int x, int y) => Modules[y * Size + x];

    /// The dark modules as horizontal runs (x, y, width): one rectangle per run, so the window
    /// draws a few hundred shapes instead of a thousand squares with hairline seams between them.
    public IEnumerable<(int X, int Y, int Width)> Runs()
    {
        for (var y = 0; y < Size; y++)
        {
            var x = 0;
            while (x < Size)
            {
                if (!Dark(x, y)) { x++; continue; }
                var start = x;
                while (x < Size && Dark(x, y)) x++;
                yield return (start, y, x - start);
            }
        }
    }
}

/// The pair screen's QR (jc-client's `pair_qr_start` payload), encoded here so the PC needs no
/// network for it. Medium error correction: a phone camera reads it off a monitor at an angle.
public static class PairQr
{
    public static QrMatrix Encode(string payload)
    {
        if (string.IsNullOrEmpty(payload)) throw new ArgumentException("nothing to encode", nameof(payload));
        var qr = QrCode.EncodeText(payload, QrCode.Ecc.Medium);
        var modules = new bool[qr.Size * qr.Size];
        for (var y = 0; y < qr.Size; y++)
            for (var x = 0; x < qr.Size; x++)
                modules[y * qr.Size + x] = qr.GetModule(x, y);
        return new QrMatrix(qr.Size, modules);
    }
}
