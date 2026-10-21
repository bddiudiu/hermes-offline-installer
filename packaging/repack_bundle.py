"""Refresh installer code in a SHA-256-pinned Windows release; keep its runtime payload."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import zipfile

from build_bundle import ROOT, validate_archive_python_stdlib, validate_archive_hermes_resources, validate_archive_hermes_source
from manifest import DEFAULT_HERMES_TAG, PYTHON_VERSION, UV_VERSION

PREFIX = 'hermes-offline-installer-win-x64/'
ROOT_SCRIPTS = {
    'install.cmd': 'install_windows.cmd', 'install_windows.cmd': 'install_windows.cmd',
    'install_silent.ps1': 'install_windows_silent.ps1', 'install_silent.vbs': 'install_windows_silent.vbs',
    'launch.cmd': 'launch_windows.cmd', 'repair.cmd': 'repair_windows.cmd',
    'shutdown.cmd': 'shutdown_windows.cmd', 'uninstall.cmd': 'uninstall_windows.cmd',
    'upgrade.cmd': 'upgrade.cmd', 'upgrade.ps1': 'upgrade.ps1',
}


def file_hash(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def script_bytes(path: Path) -> bytes:
    text = path.read_text(encoding='utf-8-sig')
    windows = path.suffix in ('.ps1', '.cmd', '.vbs')
    return text.replace('\n', '\r\n' if windows else '\n').encode('utf-8-sig' if path.suffix == '.ps1' else 'utf-8')


def repack(archive: Path, expected_hash: str, output: Path) -> dict:
    if file_hash(archive) != expected_hash:
        raise ValueError('Base release ZIP checksum mismatch')
    updates = {}
    for directory in ('installers', 'scripts'):
        for path in sorted((ROOT / directory).rglob('*')):
            if path.is_file() and path.suffix in ('.py', '.ps1', '.cmd', '.sh', '.vbs'):
                updates[path.relative_to(ROOT).as_posix()] = script_bytes(path)
    for name, source in ROOT_SCRIPTS.items():
        updates[name] = updates['installers/' + source]
    updates['UPGRADE.zh-CN.md'] = (ROOT / 'docs/upgrade-windows.zh-CN.md').read_text(encoding='utf-8').encode('utf-8')
    output.mkdir(parents=True, exist_ok=True)
    destination = output / 'hermes-offline-installer-win-x64.zip'
    with zipfile.ZipFile(archive) as base:
        entries = base.infolist()
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)) or any(not name.startswith(PREFIX) for name in names):
            raise ValueError('Unexpected base ZIP layout or duplicate entries')
        inventory = json.loads(base.read(PREFIX + 'upgrade-manifest.json'))
        files = inventory['files']
        actual = {e.filename[len(PREFIX):] for e in entries if not e.is_dir()} - {'upgrade-manifest.json'}
        if inventory['schema'] != 1 or inventory['algorithm'] != 'sha256' or actual != set(files):
            raise ValueError('Incomplete base ZIP inventory')
        manifest = json.loads(base.read(PREFIX + 'manifest.json'))
        if (manifest['hermes_version'] != DEFAULT_HERMES_TAG.removeprefix('v')
                or manifest['python_version'] != PYTHON_VERSION or manifest['uv_version'] != UV_VERSION):
            raise ValueError('Runtime version changed; a full native build is required')
        for name in ('config.yaml', 'env.template'):
            packaged = base.read(PREFIX + 'templates/' + name).decode('utf-8-sig').replace('\r\n', '\n')
            if packaged != (ROOT / 'templates' / name).read_text(encoding='utf-8-sig'):
                raise ValueError('Templates changed; a full native build is required')
        new_inventory = {}
        with zipfile.ZipFile(destination, 'x', zipfile.ZIP_DEFLATED) as result:
            for entry in entries:
                relative = entry.filename[len(PREFIX):]
                if relative == 'upgrade-manifest.json':
                    continue
                content = base.read(entry)
                if not entry.is_dir():
                    if hashlib.sha256(content).hexdigest() != files[relative]:
                        raise ValueError('Base payload checksum mismatch: ' + relative)
                    if relative.startswith(('scripts/', 'installers/')) and relative not in updates:
                        continue
                content = updates.pop(relative, content)
                # ZipFile updates header offsets when writing; keep base entries readable.
                result.writestr(copy.copy(entry), content)
                if not entry.is_dir():
                    new_inventory[relative] = hashlib.sha256(content).hexdigest()
            for relative, content in sorted(updates.items()):
                info = zipfile.ZipInfo(PREFIX + relative, (1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                result.writestr(info, content)
                new_inventory[relative] = hashlib.sha256(content).hexdigest()
            inventory_bytes = (json.dumps({'schema': 1, 'algorithm': 'sha256', 'files': dict(sorted(new_inventory.items()))}, indent=2) + '\n').encode('utf-8')
            info = zipfile.ZipInfo(PREFIX + 'upgrade-manifest.json', (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            result.writestr(info, inventory_bytes)
        config = base.read(PREFIX + 'templates/config.yaml')
    with zipfile.ZipFile(destination) as result:
        for name, expected in new_inventory.items():
            if hashlib.sha256(result.read(PREFIX + name)).hexdigest() != expected:
                raise ValueError('Repacked file mismatch: ' + name)
    validate_archive_python_stdlib('win-x64', destination)
    validate_archive_hermes_resources('win-x64', destination)
    validate_archive_hermes_source('win-x64', destination)
    (output / 'config.yaml').write_bytes(config)
    for path in (destination, output / 'config.yaml'):
        path.with_name(path.name + '.sha256').write_text(file_hash(path) + '  ' + path.name + '\n', encoding='utf-8')
    metadata = {'base_sha256': expected_hash, 'zip_sha256': file_hash(destination),
                'inventory_sha256': hashlib.sha256(inventory_bytes).hexdigest(),
                'files': len(new_inventory), 'hermes_version': manifest['hermes_version']}
    (output / 'repack-verification.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch('[a-f0-9]{64}', args.sha256):
        parser.error('--sha256 must be the trusted base release checksum')
    print(json.dumps(repack(args.archive, args.sha256, args.output), indent=2), flush=True)


if __name__ == '__main__':
    main()
