@echo off
echo ============================================================
echo  DirectStream - Local Windows Build Script
echo ============================================================
echo.
echo [1/5] Initializing Flutter Android Scaffolding...
call flutter create . --project-name tv_cast_app --platforms=android
if errorlevel 1 goto :error

echo.
echo [2/5] Copying AndroidManifest and signing config...
copy /Y android_manifest_template.xml android\app\src\main\AndroidManifest.xml
if errorlevel 1 goto :error
copy /Y keystore\key.properties android\key.properties
if errorlevel 1 goto :error

echo.
echo [3/5] Patching build.gradle for release signing...
python patch_gradle.py
if errorlevel 1 goto :error

echo.
echo [4/5] Installing dependencies and generating app icons...
call flutter pub get
if errorlevel 1 goto :error
call dart run flutter_launcher_icons
if errorlevel 1 goto :error

echo.
echo [5/5] Building Signed Release APK...
call flutter build apk --release
if errorlevel 1 goto :error

echo.
echo ============================================================
echo  BUILD SUCCESSFUL!
echo  APK: build\app\outputs\flutter-apk\app-release.apk
echo ============================================================
goto :end

:error
echo.
echo ============================================================
echo  BUILD FAILED. Check errors above.
echo ============================================================
exit /b 1

:end
pause
