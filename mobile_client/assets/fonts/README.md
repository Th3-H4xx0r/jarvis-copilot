# Bundled font — Inter

The app uses **Inter** as its app-wide font (declared in `pubspec.yaml` under
`flutter: fonts:` and applied via `JcTheme.fontFamily`).

Drop these four `.ttf` files into THIS folder (`mobile_client/assets/fonts/`):

- `Inter-Regular.ttf`   (weight 400)
- `Inter-Medium.ttf`    (weight 500)
- `Inter-SemiBold.ttf`  (weight 600)
- `Inter-Bold.ttf`      (weight 700)

Get them from the official release (free, OFL license):
https://github.com/rsms/inter/releases  → download `Inter-*.zip` →
`extras/ttf/Inter-Regular.ttf` etc. (or fonts.google.com/specimen/Inter).

Then run:

    cd mobile_client && flutter pub get && ./scripts/deploy_both.sh

Until the files are present the build still works — Flutter just falls back to
the system font for the missing weights. Once they're in, the whole app renders
in Inter, online or offline.
