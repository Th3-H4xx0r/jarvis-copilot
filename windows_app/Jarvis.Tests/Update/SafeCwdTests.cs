using Jarvis.Core.Update;
using Xunit;

namespace Jarvis.Tests.Update;

/// Live 2026-11-23: every update after the first failed "being used by another process" — the updater (and the app it
/// restarted) had its working directory inside the app folder it was trying to move aside.
public class SafeCwdTests
{
    [Fact]
    public void A_folder_inside_the_app_is_inside()
    {
        Assert.True(SafeCwd.IsInside(@"C:\Users\k\AppData\Local\Programs\Jarvis\app", @"C:\Users\k\AppData\Local\Programs\Jarvis\app"));
        Assert.True(SafeCwd.IsInside(@"C:\Users\k\AppData\Local\Programs\Jarvis\app\GlassesCamera", @"C:\Users\k\AppData\Local\Programs\Jarvis\app\"));
        Assert.True(SafeCwd.IsInside(@"c:\users\K\appdata\local\programs\jarvis\APP", @"C:\Users\k\AppData\Local\Programs\Jarvis\app"));
    }

    [Fact]
    public void A_sibling_folder_is_not_inside()
    {
        Assert.False(SafeCwd.IsInside(@"C:\Users\k\AppData\Local\Programs\Jarvis\app.old", @"C:\Users\k\AppData\Local\Programs\Jarvis\app"));
        Assert.False(SafeCwd.IsInside(@"C:\Users\k\AppData\Local\Programs\Jarvis\updater", @"C:\Users\k\AppData\Local\Programs\Jarvis\app"));
        Assert.False(SafeCwd.IsInside("", @"C:\x"));
    }

    [Fact]
    public void Outside_moves_a_working_directory_out_of_the_app()
    {
        const string app = @"C:\P\Jarvis\app", data = @"C:\L\Jarvis";
        Assert.Equal(data, SafeCwd.Outside(@"C:\P\Jarvis\app", app, data));
        Assert.Equal(@"C:\P\Jarvis\updater", SafeCwd.Outside(@"C:\P\Jarvis\updater", app, data));
    }
}
