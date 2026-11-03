"""
patch_gradle.py
Patches android/app/build.gradle to use the project's release signing keystore.
Run this AFTER `flutter create .` regenerates the android/ folder.
"""
import re
import sys
import os

GRADLE_FILE = os.path.join('android', 'app', 'build.gradle')

if not os.path.exists(GRADLE_FILE):
    print(f"ERROR: {GRADLE_FILE} not found. Run `flutter create .` first.")
    sys.exit(1)

with open(GRADLE_FILE, 'r') as f:
    content = f.read()

# ---- a) Inject key.properties loader before the android { block ----
loader = (
    'def keystorePropertiesFile = rootProject.file("key.properties")\n'
    'def keystoreProperties = new Properties()\n'
    'if (keystorePropertiesFile.exists()) {\n'
    '    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))\n'
    '}\n\n'
)
if 'keystorePropertiesFile' not in content:
    content = re.sub(r'(android\s*\{)', loader + r'\1', content, count=1)
    print("  [+] Injected key.properties loader")
else:
    print("  [=] key.properties loader already present")

# ---- b) Add signingConfigs block inside android { ----
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
else:
    print("  [=] signingConfigs already present")

# ---- c) Switch release buildType to signingConfigs.release ----
if 'signingConfig signingConfigs.debug' in content:
    content = content.replace(
        'signingConfig signingConfigs.debug',
        'signingConfig signingConfigs.release'
    )
    print("  [+] Switched release buildType to signingConfigs.release")
elif 'signingConfig signingConfigs.release' in content:
    print("  [=] signingConfigs.release already set")
else:
    print("  [!] WARNING: Could not find signingConfig line to patch")

with open(GRADLE_FILE, 'w') as f:
    f.write(content)

print(f"\nbuild.gradle patched successfully: {GRADLE_FILE}")
