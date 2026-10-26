import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/verify-app-launch.py"


@unittest.skipUnless(sys.platform == "darwin", "requires macOS dyld and codesign")
class AppLaunchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.app = root / "Probe.app"
        self.executable = self.app / "Contents/MacOS/Probe"
        self.framework = self.app / "Contents/Frameworks/Probe.framework/Versions/A/Probe"
        self.executable.parent.mkdir(parents=True)
        self.framework.parent.mkdir(parents=True)
        with (self.app / "Contents/Info.plist").open("wb") as destination:
            plistlib.dump({"CFBundleExecutable": "Probe", "CFBundleIdentifier": "test.jottie.launch",
                          "CFBundlePackageType": "APPL"}, destination)
        framework_root = self.framework.parents[2]
        resources = self.framework.parent / "Resources"
        resources.mkdir()
        with (resources / "Info.plist").open("wb") as destination:
            plistlib.dump({"CFBundleExecutable": "Probe", "CFBundleIdentifier": "test.jottie.framework",
                          "CFBundlePackageType": "FMWK"}, destination)
        (framework_root / "Versions/Current").symlink_to("A")
        (framework_root / "Probe").symlink_to("Versions/Current/Probe")
        (framework_root / "Resources").symlink_to("Versions/Current/Resources")
        source = root / "probe.c"
        source.write_text("int probe(void) { return 0; }\n")
        self.run_command("xcrun", "clang", "-dynamiclib", str(source), "-o", str(self.framework),
                         "-Wl,-install_name,@rpath/Probe.framework/Versions/A/Probe")
        source.write_text('extern int probe(void); extern int puts(const char *);\n'
                          'int main(void) { puts("USAGE: probe --help"); return probe(); }\n')
        self.run_command("xcrun", "clang", str(source), str(self.framework), "-o", str(self.executable),
                         "-Wl,-rpath,@executable_path/../Frameworks")
        self.run_command("codesign", "--force", "--sign", "-", str(framework_root))

    def run_command(self, *arguments):
        completed = subprocess.run(arguments, capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def check_bundle(self, **environment):
        return subprocess.run([sys.executable, str(CHECKER), str(self.app)],
                              env={**os.environ, **environment}, capture_output=True, text=True)

    def test_accepts_adhoc_development_bundle_with_embedded_framework(self):
        self.run_command("codesign", "--force", "--sign", "-", "--options", "0", str(self.app))
        completed = self.check_bundle()
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_rejects_hardened_adhoc_bundle_then_accepts_corrected_signature(self):
        self.run_command("codesign", "--force", "--sign", "-", "--options", "runtime", str(self.app))
        broken = self.check_bundle()
        self.assertNotEqual(broken.returncode, 0)
        self.assertIn("different Team IDs", broken.stderr)
        self.run_command("codesign", "--force", "--sign", "-", "--options", "0", str(self.app))
        fixed = self.check_bundle()
        self.assertEqual(fixed.returncode, 0, fixed.stderr)

    def test_developer_library_path_cannot_hide_missing_embedded_framework(self):
        self.run_command("codesign", "--force", "--sign", "-", "--options", "0", str(self.app))
        framework_root = self.framework.parents[2]
        developer_path = self.app.parent / "DeveloperFrameworks"
        developer_path.mkdir()
        framework_root.rename(developer_path / framework_root.name)
        completed = self.check_bundle(DYLD_FRAMEWORK_PATH=str(developer_path))
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Library not loaded", completed.stderr)


if __name__ == "__main__":
    unittest.main()
