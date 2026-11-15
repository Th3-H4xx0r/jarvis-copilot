using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace Jarvis.Tests.Ui;

/// Reads the WPF sources as text/XML (so it runs on any OS): one accent, the amber/green
/// meanings, and no colour literal outside Ui/Theme.xaml.
public class ThemeInvariantTests
{
    internal static string RepoRoot()
    {
        var d = new DirectoryInfo(AppContext.BaseDirectory);
        while (d != null && !File.Exists(Path.Combine(d.FullName, "Jarvis.sln"))) d = d.Parent;
        return d?.FullName ?? throw new DirectoryNotFoundException("Jarvis.sln not found above the test binaries");
    }

    [Fact]
    public void Theme_AccentIsWhite_AndNoHexOutsideTheme()
    {
        var root = RepoRoot();
        var theme = XDocument.Load(Path.Combine(root, "Jarvis", "Ui", "Theme.xaml"));
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        string Color(string key) => theme.Descendants().First(e => (string?)e.Attribute(x + "Key") == key).Value.Trim();
        Assert.Equal("#FFFFFFFF", Color("JcAccentColor"));
        Assert.Equal("#FFFABF24", Color("JcAmberColor"));
        Assert.Equal("#FF34D399", Color("JcGreenColor"));
        Assert.Equal("#17FFFFFF", Color("JcButtonColor"));
        Assert.Equal("#3DFFFFFF", Color("JcButtonSelectedColor"));

        var hex = new Regex(@"#[0-9A-Fa-f]{6,8}\b");
        var offenders = Directory.EnumerateFiles(Path.Combine(root, "Jarvis"), "*.*", SearchOption.AllDirectories)
            .Where(f => f.EndsWith(".xaml") || f.EndsWith(".cs"))
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}") && !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}"))
            .Where(f => !f.EndsWith(Path.Combine("Ui", "Theme.xaml")))
            .Where(f => hex.IsMatch(File.ReadAllText(f)))
            .ToList();
        Assert.Empty(offenders);
    }
}
