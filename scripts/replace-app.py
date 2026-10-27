#!/usr/bin/env python3
"""Install a verified development bundle at the same path, with rollback on failure.

Never reset TCC, change application data, or leave a second visible application.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import sqlite3
import subprocess
import time

BUNDLE_ID = 'com.gravyraveydavey.jottie'


def info(app):
    with (app / 'Contents/Info.plist').open('rb') as file:
        value = plistlib.load(file)
    if value.get('CFBundleIdentifier') != BUNDLE_ID or value.get('CFBundleExecutable') != 'Jottie':
        raise RuntimeError(f'Not a Jottie application: {app}')
    return value


def team(app):
    result = subprocess.run(['codesign', '-dv', str(app)], capture_output=True, text=True, check=True)
    for line in result.stderr.splitlines():
        if line.startswith('TeamIdentifier='):
            return line.partition('=')[2]
    return 'not set'


def running(executables):
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, text=True, check=True)
    return [int(pid) for line in result.stdout.splitlines() if len(parts := line.strip().split(None, 1)) == 2
            for pid, command in [parts] if command in executables]


def assert_idle(home):
    config = home / '.config/jottie/config.json'
    settings = json.loads(config.read_text()) if config.exists() else {}
    capture = Path(settings.get('recordings_dir', str(home / 'Library/Application Support/Jottie/Capture'))).expanduser()
    for name in ('.recording.json', '.transcribing.json'):
        for marker in capture.glob('*/' + name):
            pid = int(json.loads(marker.read_text())['pid'])
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            raise RuntimeError('Recording/transcription is active. Finish it and rebuild; the installed app is untouched.')
    ledger = home / 'Library/Application Support/Jottie/work.sqlite'
    if ledger.exists():
        with sqlite3.connect(ledger.as_uri() + '?mode=ro', uri=True) as db:
            active = db.execute("SELECT count(*) FROM jobs WHERE state='running' AND next>?", (time.time(),)).fetchone()[0]
        if active:
            raise RuntimeError('Analysis/publication is active. Finish it or quit Jottie, then rebuild; the installed app is untouched.')


def swap(source, destination):
    """Same-volume renames; retain the old bundle only until installation succeeds."""
    backup = destination.parent / '.jottie-replaced'
    if backup.exists():
        if not destination.exists():
            os.replace(backup, destination)
        else:
            shutil.rmtree(backup)
    had_previous = destination.exists()
    if had_previous:
        os.replace(destination, backup)
    try:
        os.replace(source, destination)
    except BaseException:
        if had_previous:
            os.replace(backup, destination)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def install(source, destination):
    source, destination = source.absolute(), destination.absolute()
    if source == destination or source.is_symlink() or destination.is_symlink():
        raise RuntimeError('Staging and installed bundles must be separate, real directories.')
    info(source)
    subprocess.run(['codesign', '--verify', '--strict', str(source)], check=True)
    if destination.exists():
        info(destination)
        previous, replacement = team(destination), team(source)
        if previous != 'not set' and previous != replacement:
            raise RuntimeError('Signing team changed. Rebuild using the installed app’s signing identity to preserve its identity.')
    # Clean up the specifically known old development variant, never unrelated apps.
    obsolete = destination.parent / 'Jottie-update.app'
    copies = [destination]
    if obsolete != destination and obsolete.exists():
        info(obsolete)
        copies.append(obsolete)
    executables = {str(app / 'Contents/MacOS/Jottie') for app in copies}
    pids = running(executables)
    if pids:
        assert_idle(Path.home())
        # SIGTERM is handled by the recorder and finalizes/cancels work cleanly.
        for pid in pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 20
        while running(executables):
            if time.monotonic() >= deadline:
                raise RuntimeError('Jottie is still shutting down; the installed bundle is untouched. Retry after it exits.')
            time.sleep(0.1)
    destination.parent.mkdir(parents=True, exist_ok=True)
    swap(source, destination)
    if obsolete != destination and obsolete.exists():
        shutil.rmtree(obsolete)
    print(f'Replaced {destination}; settings and library data were left in place.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('staged', type=Path)
    parser.add_argument('installed', type=Path)
    arguments = parser.parse_args()
    try:
        install(arguments.staged, arguments.installed)
    except (OSError, ValueError, KeyError, RuntimeError, sqlite3.Error, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Jottie replacement stopped: {error}\n')
