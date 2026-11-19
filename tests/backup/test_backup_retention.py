import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('backup', Path(__file__).resolve().parents[2] / 'scripts/backup-retention.py')
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class BackupFlow(unittest.TestCase):
    def test_dump_objects_manifest_and_registration(self):
        registered = []
        requested = []
        def http(request, timeout):
            requested.append(request.full_url)
            if request.full_url.endswith('/storage/v1/bucket'):
                return io.BytesIO(b'[{"id":"signatures","public":false}]')
            if '/object/list/' in request.full_url:
                payload = json.loads(request.data)
                if payload['prefix'] == '':
                    return io.BytesIO(b'[{"id":null,"name":"folder"}]')
                return io.BytesIO(b'[{"id":"object-1","name":"../../photo.png"}]')
            if '/rest/v1/rpc/' in request.full_url:
                registered.append(json.loads(request.data))
                return io.BytesIO(b'"backup-id"')
            return io.BytesIO(b'photo-content')
        def run(args, **kwargs):
            if args[0] == 'pg_dump':
                Path(args[args.index('--file')+1]).write_bytes(b'dump-content')
            else:
                # Testa orquestração e manifesto; criptografia é fornecida pelo GPG.
                Path(args[args.index('--output')+1]).write_bytes(Path(args[-1]).read_bytes())
        with tempfile.TemporaryDirectory() as directory, patch.dict(backup.os.environ, {
            'BACKUP_DIR': directory, 'BACKUP_GPG_RECIPIENT': 'test-fingerprint',
            'SUPABASE_URL': 'https://project.supabase.co', 'SUPABASE_SERVICE_ROLE_KEY': 'test-key', 'PGSERVICE': 'test'
        }), patch.object(backup.shutil, 'which', return_value='/fake'), patch.object(backup.subprocess, 'run', side_effect=run), patch.object(backup, 'urlopen', side_effect=http):
            self.assertEqual(backup.main(), 0)
            files = list(Path(directory).glob('*.tar.gpg'))
            self.assertEqual(len(files), 1)
            self.assertEqual(registered[0]['p_sha256'], backup.file_hash(files[0]))
            self.assertEqual(registered[0]['p_scope'], 'banco_e_storage')
            with tarfile.open(files[0]) as archive:
                manifest = json.load(archive.extractfile('manifest.json'))
                self.assertEqual(manifest['objects'][0]['file'], 'objects/0')
                self.assertEqual(archive.extractfile('objects/0').read(), b'photo-content')
                self.assertEqual(archive.extractfile('database.dump').read(), b'dump-content')
                self.assertFalse(manifest['consistent_snapshot'])
                self.assertEqual(backup.ten_years(backup.datetime.fromisoformat(manifest['created_at'])).isoformat(), manifest['retain_until'])
            self.assertTrue(all('test-key' not in url for url in requested))

    def test_failure_does_not_register_or_leave_partial(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(backup.os.environ, {
            'BACKUP_DIR': directory, 'BACKUP_GPG_RECIPIENT': 'test-fingerprint',
            'SUPABASE_URL': 'https://project.supabase.co', 'SUPABASE_SERVICE_ROLE_KEY': 'test-key', 'PGSERVICE': 'test'
        }), patch.object(backup.shutil, 'which', return_value='/fake'), patch.object(backup.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'pg_dump')), patch.object(backup, 'urlopen') as http:
            with self.assertRaises(subprocess.CalledProcessError):
                backup.main()
            http.assert_not_called()
            self.assertEqual(list(Path(directory).iterdir()), [])

if __name__ == '__main__':
    unittest.main()
