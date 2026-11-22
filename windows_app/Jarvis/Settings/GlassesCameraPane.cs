using System.Windows;
using System.Windows.Controls;
using Jarvis.Core.GlassesCamera;
using Jarvis.GlassesCamera;
using Jarvis.Ui;

namespace Jarvis.Settings;

/// Settings → Glasses camera (the Mac's GlassesCameraSettings): install the "Jarvis Glasses"
/// camera, see what it's doing, and what to do on the iPhone.
public static class GlassesCameraPane
{
    public static FrameworkElement Build(GlassesCamInstaller installer, GlassesCameraService service)
    {
        var p = Pane.Page("Glasses camera",
            "Your Meta glasses' live video as a PC camera. Pick “Jarvis Glasses” as the camera in Teams, Zoom, Discord or your browser; your iPhone sends the video, over Wi-Fi or cellular.");
        // Rows re-built in place (already Form rows inside).
        var cameraRow = new ContentControl { Tag = SettingsForm.RowTag };
        var nowRow = new ContentControl { Tag = SettingsForm.RowTag };
        var note = Th.Text("", 12, "JcSetSecondary", wrap: true);

        void Render()
        {
            var state = installer.State;
            var installed = state is GlassesCamInstallState.Installed;
            var working = state is GlassesCamInstallState.Working;
            var status = Th.Text(state.Text, 13, state is GlassesCamInstallState.Failed ? "JcAmber" : "JcSetSecondary", wrap: true);
            status.MaxWidth = 360;
            status.VerticalAlignment = VerticalAlignment.Center;
            var install = Th.Button(installed ? "Reinstall" : "Install camera", () => _ = installer.InstallAsync(), primary: !installed && !working);
            install.IsEnabled = !working;
            var remove = Th.Button("Remove", () => _ = installer.RemoveAsync());
            remove.IsEnabled = !working;
            cameraRow.Content = Pane.Labeled("Camera", installed ? Th.Row(10, status, install, remove) : Th.Row(10, status, install),
                "Installing asks Face ID on your iPhone, then Windows' Yes, once: the camera stays after restarts.");
            nowRow.Content = Pane.Labeled("Right now", Th.Text(service.PhaseText, 13, "JcSetSecondary", wrap: true));
            note.Text = installer.Note ?? "";
        }

        void Later() => p.Dispatcher.BeginInvoke(Render);
        installer.Changed += Later;
        service.Changed += Later;
        p.Unloaded += (_, _) =>
        {
            installer.Changed -= Later;
            service.Changed -= Later;
        };

        p.Children.Add(Pane.Section("Jarvis Glasses camera"));
        p.Children.Add(cameraRow);
        p.Children.Add(nowRow);
        p.Children.Add(note);
        p.Children.Add(Pane.Section("On your iPhone"));
        p.Children.Add(Th.Text("Meta glasses → Watch live → Send to computer camera.", 13, "JcSetLabel", wrap: true));
        p.Children.Add(Pane.Footer("Video only flows while your glasses are live and an app on this PC is using the camera; otherwise the camera shows “Glasses not streaming”. Nothing runs while no app uses it, so games keep every frame."));
        Render();
        _ = installer.RefreshAsync();
        service.Refresh();
        return p;
    }
}
