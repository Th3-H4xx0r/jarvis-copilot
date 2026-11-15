using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Jarvis.Ui;

/// Draws a view to a PNG for desktop verification (`--diag settings-shot`, `orbit-shot`), laid
/// out at the given size when its window isn't on screen.
internal static class Snap
{
    public static void Save(FrameworkElement view, double width, double height, string path)
    {
        try
        {
            if (view.ActualWidth < 1 || !view.IsVisible)
            {
                view.Measure(new Size(width, height));
                view.Arrange(new Rect(0, 0, width, height));
                view.UpdateLayout();
            }
            else (width, height) = (view.ActualWidth, view.ActualHeight);
            var bmp = new RenderTargetBitmap((int)(width * 1.5), (int)(height * 1.5), 144, 144, PixelFormats.Pbgra32);
            var bg = new DrawingVisual();
            using (var dc = bg.RenderOpen()) dc.DrawRectangle(Th.B("JcSetWindow"), null, new Rect(0, 0, width, height));
            bmp.Render(bg);
            bmp.Render(view);
            var png = new PngBitmapEncoder();
            png.Frames.Add(BitmapFrame.Create(bmp));
            using var f = File.Create(path);
            png.Save(f);
        }
        catch (Exception e)
        {
            Platform.FileLog.Write("app", $"snap failed: {e.Message}");
        }
    }
}
