"""Offline checks for the native-runner setup script; Flutter itself is separate."""

import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET


SCRIPT = Path(__file__).resolve().parents[2] / "apps/frontend/tool/bootstrap.py"
SPEC = importlib.util.spec_from_file_location("frontend_bootstrap", SCRIPT)
bootstrap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bootstrap)


class FrontendBootstrapTests(unittest.TestCase):
    def make_platforms(self, root):
        for kind in ("main", "debug"):
            path = root / f"android/app/src/{kind}/AndroidManifest.xml"
            path.parent.mkdir(parents=True)
            path.write_text(
                f'<manifest xmlns:android="{bootstrap.ANDROID}">'
                '<application android:label="original" /></manifest>'
            )
        gradle = root / "android/app/build.gradle.kts"
        gradle.write_text("minSdk = flutter.minSdkVersion\n")
        info = root / "ios/Runner/Info.plist"
        info.parent.mkdir(parents=True)
        with info.open("wb") as stream:
            plistlib.dump({"ExistingKey": "preserved"}, stream)

    def test_platform_permissions_are_idempotent_and_preserve_existing_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_platforms(root)
            bootstrap.configure_platforms(root)
            original = {path: path.read_bytes() for path in root.rglob("*") if path.is_file()}
            bootstrap.configure_platforms(root)
            self.assertEqual(original, {path: path.read_bytes() for path in original})
            main = ET.parse(root / "android/app/src/main/AndroidManifest.xml").getroot()
            permission = f"{{{bootstrap.ANDROID}}}name"
            self.assertEqual([node.get(permission) for node in main.findall("uses-permission")],
                             ["android.permission.INTERNET"])
            cleartext = f"{{{bootstrap.ANDROID}}}usesCleartextTraffic"
            self.assertNotIn(cleartext, main.find("application").attrib)
            debug = ET.parse(root / "android/app/src/debug/AndroidManifest.xml").getroot()
            self.assertEqual(debug.find("application").get(cleartext), "true")
            with (root / "ios/Runner/Info.plist").open("rb") as stream:
                values = plistlib.load(stream)
            self.assertEqual(values["ExistingKey"], "preserved")
            self.assertTrue(values["NSCameraUsageDescription"])
            self.assertTrue(values["NSPhotoLibraryUsageDescription"])

    def test_setup_preserves_application_files_and_runs_flutter_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_platforms(root)
            app_files = [root / "lib/main.dart", root / "test/widget_test.dart", root / "pubspec.yaml"]
            for path in app_files:
                path.parent.mkdir(exist_ok=True)
                path.write_text("preserve this app file\n")
            with patch.object(bootstrap, "FRONTEND", root), \
                 patch.object(bootstrap.shutil, "which", side_effect=lambda name: f"/sdk/bin/{name}"), \
                 patch.object(bootstrap.subprocess, "run") as run, \
                 patch("sys.argv", [str(SCRIPT), "--check"]), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(bootstrap.main(), 0)
            self.assertEqual([call.args[0][1:] for call in run.call_args_list], [
                ["pub", "get"], ["format", "lib", "test"], ["analyze", "--no-fatal-infos"], ["test"],
            ])
            self.assertTrue(all(path.read_text() == "preserve this app file\n" for path in app_files))

    def test_missing_flutter_reports_setup_requirement_without_modifying_files(self):
        with patch.object(bootstrap.shutil, "which", return_value=None), \
             patch.object(bootstrap.subprocess, "run") as run, \
             patch("sys.argv", [str(SCRIPT)]), contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertEqual(bootstrap.main(), 1)
        self.assertIn("Flutter is not on PATH", output.getvalue())
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
