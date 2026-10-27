import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('replace_app', ROOT / 'scripts/replace-app.py')
replace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replace)


class AppReplacementTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.bundle('.staging/Jottie.app', 'new')
        self.destination = self.bundle('Jottie.app', 'old')

    def bundle(self, path, revision):
        app = self.root / path
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/MacOS/Jottie').write_text(revision)
        with (app / 'Contents/Info.plist').open('wb') as file:
            plistlib.dump({'CFBundleIdentifier': replace.BUNDLE_ID, 'CFBundleExecutable': 'Jottie'}, file)
        return app

    def revision(self):
        return (self.destination / 'Contents/MacOS/Jottie').read_text()

    def test_verified_replacement_leaves_one_bundle_and_keeps_external_settings(self):
        self.bundle('Jottie-update.app', 'obsolete')
        settings = self.root / 'config.json'
        settings.write_text('saved preferences')
        with patch.object(replace.subprocess, 'run'), patch.object(replace, 'team', return_value='not set'), patch.object(replace, 'running', return_value=[]):
            replace.install(self.source, self.destination)
        self.assertEqual(self.revision(), 'new')
        self.assertEqual(settings.read_text(), 'saved preferences')
        self.assertEqual(list(self.root.glob('*.app')), [self.destination])
        self.assertFalse(self.source.exists())
        self.assertFalse((self.root / '.jottie-replaced').exists())

    def test_failed_swap_restores_complete_previous_bundle(self):
        real_replace = os.replace
        def fail_install(source, destination):
            if source == self.source:
                raise OSError('simulated interrupted install')
            real_replace(source, destination)
        with patch.object(replace.os, 'replace', side_effect=fail_install):
            with self.assertRaises(OSError):
                replace.swap(self.source, self.destination)
        self.assertEqual(self.revision(), 'old')
        self.assertFalse((self.root / '.jottie-replaced').exists())

    def test_capture_prevents_shutdown_and_replacement(self):
        marker = self.root / 'Library/Application Support/Jottie/Capture/meeting/.recording.json'
        marker.parent.mkdir(parents=True)
        marker.write_text(json.dumps({'pid': os.getpid()}))
        with patch.object(replace.subprocess, 'run'), patch.object(replace, 'team', return_value='not set'), patch.object(replace, 'running', return_value=[os.getpid()]), patch.object(replace.Path, 'home', return_value=self.root), patch.object(replace.os, 'kill', wraps=os.kill) as kill:
            with self.assertRaisesRegex(RuntimeError, 'active'):
                replace.install(self.source, self.destination)
            kill.assert_called_once_with(os.getpid(), 0)
        self.assertEqual(self.revision(), 'old')

    def test_signing_team_change_is_rejected_before_shutdown(self):
        with patch.object(replace.subprocess, 'run'), patch.object(replace, 'team', side_effect=['stable-team', 'not set']), patch.object(replace, 'running') as running:
            with self.assertRaisesRegex(RuntimeError, 'Signing team changed'):
                replace.install(self.source, self.destination)
            running.assert_not_called()
        self.assertEqual(self.revision(), 'old')
