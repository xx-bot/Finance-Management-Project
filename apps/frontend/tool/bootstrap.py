"""Generate Flutter platform runners without replacing lib/, tests, or pubspec.yaml.

Run from anywhere: python apps/frontend/tool/bootstrap.py
Use --check to also run formatting, analysis, and tests after dependency resolution.
"""

import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

FRONTEND = Path(__file__).resolve().parents[1]
ANDROID = 'http://schemas.android.com/apk/res/android'
ET.register_namespace('android', ANDROID)


def configure_platforms(frontend):
    manifest = frontend / 'android/app/src/main/AndroidManifest.xml'
    if manifest.exists():
        tree = ET.parse(manifest)
        root = tree.getroot()
        if not any(node.get(f'{{{ANDROID}}}name') == 'android.permission.INTERNET'
                   for node in root.findall('uses-permission')):
            root.insert(0, ET.Element('uses-permission', {f'{{{ANDROID}}}name': 'android.permission.INTERNET'}))
        application = root.find('application')
        if application is not None:
            application.set(f'{{{ANDROID}}}label', 'Pocket Ledger')
        ET.indent(tree, space='    ')
        tree.write(manifest, encoding='unicode')
    # Permit a local HTTP backend during Android debug development only.
    debug = frontend / 'android/app/src/debug/AndroidManifest.xml'
    if debug.exists():
        tree = ET.parse(debug)
        root = tree.getroot()
        application = root.find('application')
        if application is None:
            application = ET.SubElement(root, 'application')
        application.set(f'{{{ANDROID}}}usesCleartextTraffic', 'true')
        ET.indent(tree, space='    ')
        tree.write(debug, encoding='unicode')
    for path in (frontend / 'android/app/build.gradle.kts', frontend / 'android/app/build.gradle'):
        if path.exists():
            source = path.read_text()
            source = source.replace('minSdk = flutter.minSdkVersion', 'minSdk = maxOf(flutter.minSdkVersion, 24)')
            source = source.replace('minSdkVersion flutter.minSdkVersion', 'minSdkVersion Math.max(flutter.minSdkVersion, 24)')
            path.write_text(source)
    info = frontend / 'ios/Runner/Info.plist'
    if info.exists():
        with info.open('rb') as file:
            values = plistlib.load(file)
        values.update({
            'CFBundleDisplayName': 'Pocket Ledger',
            'NSCameraUsageDescription': 'Take a receipt photo to review and record an expense.',
            'NSPhotoLibraryUsageDescription': 'Choose a receipt photo to review and record an expense.',
        })
        with info.open('wb') as file:
            plistlib.dump(values, file, sort_keys=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    flutter = shutil.which('flutter')
    if flutter is None:
        print('Flutter is not on PATH. Install the Flutter SDK, run flutter doctor, then rerun this command.', file=sys.stderr)
        return 1
    if any(not (FRONTEND / platform).is_dir() for platform in ('android', 'ios')):
        with tempfile.TemporaryDirectory(prefix='pocket-flutter-') as directory:
            scaffold = Path(directory) / 'pocket_ledger'
            subprocess.run([
                flutter, 'create', '--no-pub', '--project-name', 'pocket_ledger', '--org', 'com.pocketledger',
                '--platforms', 'android,ios', '--android-language', 'kotlin', '--ios-language', 'swift', str(scaffold),
            ], check=True)
            for platform in ('android', 'ios'):
                target = FRONTEND / platform
                if not target.exists():
                    shutil.copytree(scaffold / platform, target)
            if not (FRONTEND / '.metadata').exists():
                shutil.copy2(scaffold / '.metadata', FRONTEND / '.metadata')
    configure_platforms(FRONTEND)
    subprocess.run([flutter, 'pub', 'get'], cwd=FRONTEND, check=True)
    if args.check:
        dart = shutil.which('dart') or str(Path(flutter).resolve().parent / 'dart')
        subprocess.run([str(dart), 'format', 'lib', 'test'], cwd=FRONTEND, check=True)
        subprocess.run([flutter, 'analyze', '--no-fatal-infos'], cwd=FRONTEND, check=True)
        subprocess.run([flutter, 'test'], cwd=FRONTEND, check=True)
    print(f'Pocket Ledger platform setup is complete in {FRONTEND}.')
    print('Start an Android emulator or connect an Android phone with USB debugging enabled.')
    print('From apps/frontend, run: flutter devices')
    print('Then launch with its Android device ID: flutter run -d YOUR_ANDROID_DEVICE_ID')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        raise SystemExit(exc.returncode) from exc
