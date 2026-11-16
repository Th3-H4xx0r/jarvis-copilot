using System.Windows;
using System.Windows.Controls;
using Jarvis.Settings;
using Jarvis.Ui;

namespace Jarvis.Remote;

/// Settings → PC power → Remote Desktop: needs Pro → Upgrade; on Pro the three readiness rows, Set up /
/// Repair (Face ID + UAC) and the Microsoft account password RDP signs in with.
public static class RemoteDesktopSection
{
    public static FrameworkElement Build(RemoteDesktop rdp)
    {
        var host = new ContentControl();
        var note = Th.Text("", 12, "JcSetSecondary", wrap: true);

        void Render()
        {
            if (!RemoteDesktop.IsPro)
            {
                host.Content = Pane.Group(Pane.Section("Remote Desktop"),
                    Pane.Labeled("Windows edition", Th.Row(10, Th.Text(RemoteDesktop.ProductName, 13, "JcSetSecondary"),
                        Th.Button("Upgrade to Pro", () => Open("ms-settings:activation"), primary: true)),
                        "Remote Desktop needs Windows 11 Pro. Upgrading keeps your apps and files (Settings → System → Activation)."),
                    note);
                return;
            }
            var ready = RemoteDesktop.RdpEnabled && rdp.FirewallScoped && RemoteDesktop.HelloOnlyOff;
            var box = new PasswordBox { Width = 180 };
            host.Content = Pane.Group(Pane.Section("Remote Desktop"),
                Pane.Labeled("Remote Desktop", Th.Text(RemoteDesktop.RdpEnabled ? "On" : "Off", 13, "JcSetSecondary")),
                Pane.Labeled("Who can connect", Th.Text(rdp.FirewallScoped ? "Only your Tailscale devices" : "Not set up", 13, "JcSetSecondary")),
                Pane.Labeled("Password sign-in", Th.Text(RemoteDesktop.HelloOnlyOff ? "Allowed" : "Blocked (Windows Hello only)", 13, "JcSetSecondary")),
                Pane.Labeled("Set up", Th.Button(ready ? "Repair" : "Set up", () => _ = SetUp(), primary: !ready),
                    "Turns on Remote Desktop for your Tailscale devices only and allows password sign-in. Asks Face ID on your iPhone, then Windows' Yes."),
                Pane.Labeled("Signs in as", Th.Text(rdp.Username, 13, "JcSetSecondary")),
                Pane.Labeled("Microsoft account password",
                    Th.Row(8, box, Th.Button(rdp.HasPassword ? "Replace" : "Save", () =>
                    {
                        if (box.Password.Length == 0) { note.Text = "Type your Microsoft account password (not your PIN)."; return; }
                        rdp.SavePassword(box.Password);
                        box.Clear();
                        note.Text = "Saved, encrypted for your Windows account. It's released only after Face ID on your iPhone.";
                    }), rdp.HasPassword ? Th.Button("Forget", rdp.ForgetPassword) : new TextBlock()),
                    rdp.HasPassword ? "Saved. Used to sign in to Remote Desktop after Face ID."
                        : "Remote Desktop can't use your PIN. Kept encrypted on this PC; never stored on the server."),
                note);
        }

        async Task SetUp()
        {
            note.Text = "Approve on your iPhone, then click Yes on Windows' prompt…";
            var r = await rdp.SetUpAsync();
            note.Text = r.Ok ? "Remote Desktop is on for your Tailscale devices." : r.Message;
        }

        rdp.Changed += () => host.Dispatcher.BeginInvoke(Render);
        Render();
        return host;
    }

    private static void Open(string uri)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(uri) { UseShellExecute = true }); }
        catch (System.ComponentModel.Win32Exception) { }
    }
}
