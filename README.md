# Home Cam – use a spare phone as a WiFi home camera (Flutter)

Turn a spare Android phone into a home camera you watch from another phone on the same WiFi.

- **Camera mode** (spare phone): shows a web address like `192.168.1.5:8080`. Keep it on this screen and plugged in.
- **Viewer mode** (your phone): type that address and tap *Watch live*.

Any browser on the same WiFi can also open the address directly — no second app needed.

## Watching from outside the house
This app streams only on your local WiFi. To watch while you are away, install **Tailscale** (free) on both phones and sign in with the same account; then use the camera phone's Tailscale IP in the viewer. No server or router setup needed.

## Get the APK
Built on GitHub and published here on every push:
https://github.com/mdrafioffice-create/Gallery_app/releases/tag/home-cam-latest

Open that page in Chrome on the phone, tap **HomeCam.apk**, then install.

## Note
Live video must be tested on real phones; framerate is modest because the phone converts each frame itself. If the picture is sideways, laggy, or wrong-coloured, that is tunable — say what you see.
