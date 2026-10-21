from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packaging'))
import repack_bundle as repack


class RepackBundleTests(unittest.TestCase):
    def test_refreshes_entrypoints_preserves_payload_and_leaves_base_readable(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            repo = root / 'repo'
            for directory in ('installers', 'scripts', 'templates', 'docs'):
                (repo / directory).mkdir(parents=True)
            for source in set(repack.ROOT_SCRIPTS.values()):
                (repo / 'installers' / source).write_text('new source\n', encoding='utf-8')
            (repo / 'scripts/helper.py').write_text('new helper\n', encoding='utf-8')
            (repo / 'docs/upgrade-windows.zh-CN.md').write_text('updated guide\n', encoding='utf-8')
            for name in ('config.yaml', 'env.template'):
                (repo / 'templates' / name).write_text('preserved template\n', encoding='utf-8')
            payload = {
                'runtime/python/python.exe': b'unchanged binary runtime',
                'hermes-agent/source.py': b'unchanged upstream source',
                'wheelhouse/dependency.whl': b'unchanged dependency',
                'scripts/helper.py': b'old helper\r\n',
                'scripts/removed.py': b'obsolete helper',
                'upgrade.ps1': b'old entrypoint',
                'templates/config.yaml': b'preserved template\r\n',
                'templates/env.template': b'preserved template\r\n',
                'manifest.json': json.dumps({'hermes_version': repack.DEFAULT_HERMES_TAG.removeprefix('v'),
                                             'python_version': repack.PYTHON_VERSION,
                                             'uv_version': repack.UV_VERSION}).encode(),
            }
            inventory = {'schema': 1, 'algorithm': 'sha256', 'files':
                         {name: hashlib.sha256(data).hexdigest() for name, data in payload.items()}}
            archive = root / 'base.zip'
            with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
                for name, data in payload.items():
                    z.writestr(repack.PREFIX + name, data)
                z.writestr(repack.PREFIX + 'upgrade-manifest.json', json.dumps(inventory))
            original_hash = repack.file_hash(archive)
            with mock.patch.object(repack, 'ROOT', repo), \
                 mock.patch.object(repack, 'validate_archive_python_stdlib'), \
                 mock.patch.object(repack, 'validate_archive_hermes_resources'), \
                 mock.patch.object(repack, 'validate_archive_hermes_source'):
                result = repack.repack(archive, original_hash, root / 'output')
                with self.assertRaises(FileExistsError):
                    repack.repack(archive, original_hash, root / 'output')
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    repack.repack(archive, '0' * 64, root / 'bad-output')
            self.assertEqual(repack.file_hash(archive), original_hash)
            self.assertEqual((root / 'output/config.yaml').read_bytes(), payload['templates/config.yaml'])
            with zipfile.ZipFile(root / 'output/hermes-offline-installer-win-x64.zip') as z:
                self.assertEqual(z.read(repack.PREFIX + 'runtime/python/python.exe'), payload['runtime/python/python.exe'])
                self.assertEqual(z.read(repack.PREFIX + 'upgrade.ps1'), b'\xef\xbb\xbfnew source\r\n')
                self.assertEqual(z.read(repack.PREFIX + 'upgrade.ps1'), z.read(repack.PREFIX + 'installers/upgrade.ps1'))
                self.assertNotIn(repack.PREFIX + 'scripts/removed.py', z.namelist())
                data = z.read(repack.PREFIX + 'upgrade-manifest.json')
                self.assertEqual(hashlib.sha256(data).hexdigest(), result['inventory_sha256'])
                for name, expected in json.loads(data)['files'].items():
                    self.assertEqual(hashlib.sha256(z.read(repack.PREFIX + name)).hexdigest(), expected)


if __name__ == '__main__':
    unittest.main()
