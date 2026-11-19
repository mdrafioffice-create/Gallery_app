# My Gallery – Flutter phone gallery app

Features: albums, photo + video grid, full-screen swipe, pinch-zoom, video player, share, delete.

## Build the APK (on a PC)

1. Install Flutter: https://docs.flutter.dev/get-started/install (plus Android Studio for the Android SDK).
2. Create the project:
   ```
   flutter create gallery_app
   cd gallery_app
   ```
3. Replace `pubspec.yaml` and `lib/main.dart` with the files from this zip.
4. Open `android/app/src/main/AndroidManifest.xml` and paste these lines
   just **above** the `<application` tag:
   ```xml
   <uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
   <uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
   <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
       android:maxSdkVersion="32" />
   <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
       android:maxSdkVersion="29" />
   ```
   And add `android:requestLegacyExternalStorage="true"` inside the `<application ...>` tag.
5. Copy the `assets` folder (app icon) into the project too, then run:
   ```
   flutter pub get
   dart run flutter_launcher_icons
   flutter build apk --release
   ```
6. Your APK is at `build/app/outputs/flutter-apk/app-release.apk`.
   Copy it to your phone and install (allow "Install unknown apps").

## No PC?

Upload the project to GitHub and build it for free with Codemagic
(codemagic.io) — it gives you a downloadable APK.

## Change the app name

Edit `android:label="..."` in `AndroidManifest.xml`.
