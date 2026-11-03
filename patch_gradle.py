"""
patch_gradle.py
Patches android/app/build.gradle.kts (Kotlin DSL) or android/app/build.gradle (Groovy DSL)
to use the project's release signing keystore.
Run this AFTER `flutter create .` regenerates the android/ folder.
"""
import re
import sys
import os

APP_DIR = os.path.join('android', 'app')
GRADLE_KTS = os.path.join(APP_DIR, 'build.gradle.kts')
GRADLE_GROOVY = os.path.join(APP_DIR, 'build.gradle')


def patch_kts(path):
    print(f"[*] Patching Kotlin DSL: {path}")
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    # 1. Imports at top of file
    imports = "import java.io.FileInputStream\nimport java.util.Properties\n\n"
    if "import java.io.FileInputStream" not in content:
        content = imports + content
        print("  [+] Injected Java imports")

    # 2. Load key.properties before android { block
    loader = (
        'val keystoreProperties = Properties()\n'
        'val keystorePropertiesFile = rootProject.file("key.properties")\n'
        'if (keystorePropertiesFile.exists()) {\n'
        '    keystoreProperties.load(FileInputStream(keystorePropertiesFile))\n'
        '}\n\n'
    )
    if "keystorePropertiesFile" not in content:
        content = re.sub(r'(android\s*\{)', loader + r'\1', content, count=1)
        print("  [+] Injected keystoreProperties loader")

    # 3. Add signingConfigs inside android {
    signing_block = (
        '\n    signingConfigs {\n'
        '        create("release") {\n'
        '            keyAlias = keystoreProperties["keyAlias"] as String?\n'
        '            keyPassword = keystoreProperties["keyPassword"] as String?\n'
        '            storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }\n'
        '            storePassword = keystoreProperties["storePassword"] as String?\n'
        '        }\n'
        '    }\n'
    )
    if 'create("release")' not in content:
        content = re.sub(r'(\s+buildTypes\s*\{)', signing_block + r'\1', content, count=1)
        print("  [+] Added signingConfigs.release block")

    # 4. Point release buildType to release signingConfig
    if 'signingConfigs.getByName("release")' not in content:
        content = re.sub(
            r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
            'signingConfig = signingConfigs.getByName("release")',
            content
        )
        content = re.sub(
            r'signingConfig\s*=\s*signingConfigs\.debug',
            'signingConfig = signingConfigs.getByName("release")',
            content
        )
        print("  [+] Switched release buildType to signingConfigs.release")

    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"[OK] Patched {path} successfully!")


def patch_groovy(path):
    print(f"[*] Patching Groovy DSL: {path}")
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    loader = (
        'def keystorePropertiesFile = rootProject.file("key.properties")\n'
        'def keystoreProperties = new Properties()\n'
        'if (keystorePropertiesFile.exists()) {\n'
        '    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))\n'
        '}\n\n'
    )
    if 'keystorePropertiesFile' not in content:
        content = re.sub(r'(android\s*\{)', loader + r'\1', content, count=1)
        print("  [+] Injected keystoreProperties loader")

    signing_block = (
        '\n    signingConfigs {\n'
        '        release {\n'
        "            keyAlias keystoreProperties['keyAlias']\n"
        "            keyPassword keystoreProperties['keyPassword']\n"
        "            storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null\n"
        "            storePassword keystoreProperties['storePassword']\n"
        '        }\n'
        '    }\n'
    )
    if 'signingConfigs' not in content:
        content = re.sub(r'(\s+buildTypes\s*\{)', signing_block + r'\1', content, count=1)
        print("  [+] Added signingConfigs.release block")

    content = content.replace(
        'signingConfig signingConfigs.debug',
        'signingConfig signingConfigs.release'
    )
    print("  [+] Switched release buildType to signingConfigs.release")

    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"[OK] Patched {path} successfully!")


def main():
    if os.path.exists(GRADLE_KTS):
        patch_kts(GRADLE_KTS)
    elif os.path.exists(GRADLE_GROOVY):
        patch_groovy(GRADLE_GROOVY)
    else:
        print(f"ERROR: Neither {GRADLE_KTS} nor {GRADLE_GROOVY} found!")
        if os.path.exists('android'):
            print("Contents of android/:")
            for root, dirs, files in os.walk('android'):
                for f in files:
                    print(f"  {os.path.join(root, f)}")
        else:
            print("android/ folder does not exist at all.")
        sys.exit(1)


if __name__ == '__main__':
    main()
