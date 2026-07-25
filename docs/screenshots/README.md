# Screenshots

| File | Platform | How it was captured |
|---|---|---|
| `linux_native.png` | Linux | Real screenshot of the release build (`flutter build linux`) running under Xvfb, with a seeded demo workspace. |
| `android_my_work.png` | Android form factor | Rendered by the real app code via the Flutter test harness (`tool/make_screenshots_test.dart`) at Pixel-class dimensions with `TargetPlatform.android`. |
| `ios_board.png` | iOS form factor | Same harness, iPhone-class dimensions, `TargetPlatform.iOS`. |
| `macos_projects.png` | macOS form factor | Same harness, desktop window, `TargetPlatform.macOS`. |
| `windows_board.png` | Windows form factor | Same harness, desktop window, `TargetPlatform.windows`. |

Regenerate the harness renders with:

```sh
flutter test tool/make_screenshots_test.dart
```

The Linux screenshot workflow (root shell with Xvfb + xdotool + imagemagick):

```sh
flutter build linux --release
Xvfb :99 -screen 0 1440x900x24 &
DISPLAY=:99 ./build/linux/x64/release/bundle/waypoint &   # first run creates the db
pkill -f bundle/waypoint
SEED_DB_PATH=~/.local/share/com.waypoint.waypoint/waypoint.sqlite \
  flutter test tool/seed_db_test.dart
DISPLAY=:99 ./build/linux/x64/release/bundle/waypoint &
DISPLAY=:99 import -window root docs/screenshots/linux_native.png
```

Note: only the Linux image is a native OS capture. The other four are true
renders of the app's widget tree (real layout, theming and platform
adaptations) but were not taken on physical devices.
