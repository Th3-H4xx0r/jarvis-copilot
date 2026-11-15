using Jarvis.Core.Ui;

namespace Jarvis.Core.Holo;

/// The Orbit popup's geometry (port of `HoloOrbitLayout`): devices on a ring around the item,
/// the nearest one lit, and a fling's direction picking a device.
///
/// Angles here are the fling's: degrees, 0 = right, 90 = up, counter-clockwise (so a
/// FlingDetector angle feeds `Pick` directly). A device's bearing is a compass angle (0 =
/// straight ahead = up, clockwise), turned into this one as 90 − bearing.
public static class HoloOrbitLayout
{
    public static IReadOnlyList<(HoloDevice Device, double AngleDeg)> Place(IReadOnlyList<HoloDevice> devices)
    {
        var unknown = devices.Where(d => d.Bearing == null).ToList();
        var step = unknown.Count == 0 ? 0 : 360.0 / unknown.Count;
        return devices.Select(d =>
        {
            var compass = d.Bearing ?? unknown.IndexOf(d) * step;
            return (d, Normalise(90 - compass));
        }).ToList();
    }

    /// The device a fling points at: within `maxOffDeg` of the throw's angle, the closest.
    public static HoloDevice? Pick(double angleDeg, IReadOnlyList<(HoloDevice, double)> placed, double maxOffDeg = 35) =>
        placed.Select(p => (Device: p.Item1, Gap: Gap(angleDeg, p.Item2)))
            .Where(p => p.Gap <= maxOffDeg)
            .OrderBy(p => p.Gap)
            .Select(p => p.Device)
            .FirstOrDefault();

    /// Centre of each bubble on a ring of `radius` around `centre` (screen coordinates, y down).
    public static IReadOnlyDictionary<string, PointD> Positions(IReadOnlyList<(HoloDevice Device, double AngleDeg)> placed,
        PointD centre, double radius) =>
        placed.ToDictionary(p => p.Device.Id, p =>
        {
            var r = p.AngleDeg * Math.PI / 180;
            return new PointD(centre.X + radius * Math.Cos(r), centre.Y - radius * Math.Sin(r));
        });

    /// The device to light up: the closest by distance, else the surest bearing.
    public static HoloDevice? Nearest(IReadOnlyList<HoloDevice> devices) =>
        devices.Where(d => d.Distance != null).MinBy(d => d.Distance)
        ?? devices.Where(d => d.Bearing != null && d.BearingConfidence > 0).MaxBy(d => d.BearingConfidence);

    public static double Normalise(double deg)
    {
        var r = deg % 360;
        return r < 0 ? r + 360 : r;
    }

    public static double Gap(double a, double b)
    {
        var d = Math.Abs(Normalise(a) - Normalise(b));
        return Math.Min(d, 360 - d);
    }
}
