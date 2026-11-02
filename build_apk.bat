@echo off
echo Initializing Flutter Android Scaffolding...
call flutter create . --project-name tv_cast_app --platforms=android
copy /Y android_manifest_template.xml android\app\src\main\AndroidManifest.xml
call flutter pub get
echo Building APK...
call flutter build apk --debug
echo.
echo Done! Your APK is ready at: build\app\outputs\flutter-apk\app-debug.apk
pause
