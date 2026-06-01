# Bundled font — Inter

The app's font is **Inter** (OFL license), bundled here as four static weights:

- `Inter-Regular.ttf`   (weight 400)
- `Inter-Medium.ttf`    (weight 500)
- `Inter-SemiBold.ttf`  (weight 600)
- `Inter-Bold.ttf`      (weight 700)

These are committed and declared in `pubspec.yaml` (`flutter: fonts:`) and applied
app-wide via `JcTheme.fontFamily` / `textTheme.apply(fontFamily: 'Inter')`. No
runtime fetch — they render on every device, online or off.

Source: extracted from the official release at
https://github.com/rsms/inter/releases (`extras/ttf/Inter-*.ttf`).

To update Inter later: download a newer release, replace these four files
(keep the names), `flutter pub get`, rebuild.
