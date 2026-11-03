# DirectStream (TV Receiver & Mobile Controller)

A dual-mode Flutter Android app: run it on your **TV** to receive streams, and on your **Phone** to discover and cast YouTube, Instagram Reels, IPTV (.m3u8), and direct video links — even through router AP Isolation.

---

## How to Build the APK

### Option 1: Local Windows Build
1. Ensure the **Flutter SDK** is installed and on your PATH.
2. Double-click **`build_apk.bat`**.
3. Your installable APK will be at:
   ```
   build\app\outputs\flutter-apk\app-release.apk
   ```

### Option 2: Free Cloud Build via GitHub Actions (Recommended)
1. Push your code to the `main` branch on GitHub.
2. GitHub Actions automatically:
   - Generates the custom app icon
   - Builds a **release APK**
   - Creates a **GitHub Release** tagged with the version from `pubspec.yaml`
   - Uploads the APK as a release asset
3. Go to the **Releases** section of the repo to download the latest APK.

The in-app **"Check Update"** button checks `/releases/latest` on GitHub and will offer to download and install the new APK automatically.

---

## Version Bumping

To trigger a new release with a higher version number:

1. Edit `pubspec.yaml` — increment `version`, for example:
   ```yaml
   version: 0.0.5+5   # format: semver+buildNumber
   ```
2. Push to `main`. GitHub Actions picks it up and publishes a new release tagged `v0.0.5+5`.
3. Any installed app with build number < 5 will be offered the update automatically.
