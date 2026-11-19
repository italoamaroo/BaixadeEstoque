#!/usr/bin/env python3
"""Backup cifrado de banco + Storage. Não agenda, envia emails nem elimina cópias.
Configuração e restauração: docs/RETENCAO_ADICIONAL.md. Apenas operação manual.
"""
import calendar
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen
import uuid


def ten_years(value):
    year = value.year + 10
    return value.replace(year=year, day=min(value.day, calendar.monthrange(year, value.month)[1]))


def main():
    required = ['BACKUP_DIR', 'BACKUP_GPG_RECIPIENT', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'PGSERVICE']
    missing = [key for key in required if not os.environ.get(key)]
    if missing:
        raise ValueError('Configure: ' + ', '.join(missing))
    for executable in ['pg_dump', 'gpg']:
        if not shutil.which(executable):
            raise ValueError('Comando necessário: ' + executable)
    origin = os.environ['SUPABASE_URL'].rstrip('/')
    parsed = urlparse(origin)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment:
        raise ValueError('SUPABASE_URL deve conter somente a origem HTTPS do projeto.')
    directory = Path(os.environ['BACKUP_DIR'])
    if not directory.is_absolute() or not directory.is_dir():
        raise ValueError('BACKUP_DIR deve ser uma pasta absoluta já existente no armazenamento de guarda.')
    key = os.environ['SUPABASE_SERVICE_ROLE_KEY']
    headers = {'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'}

    def api(path, payload=None):
        data = None if payload is None else json.dumps(payload).encode()
        return urlopen(Request(origin + path, data=data, headers=headers), timeout=120)

    def json_api(path, payload=None):
        with api(path, payload) as response:
            return json.load(response)

    created = datetime.now(timezone.utc)
    name = created.strftime('%Y%m%dT%H%M%SZ') + '-' + str(uuid.uuid4()) + '.tar.gpg'
    output = directory / name
    partial = directory / (name + '.partial')
    manifest = {'created_at': created.isoformat(), 'retain_until': ten_years(created).isoformat(),
                'scope': 'banco_e_storage', 'objects': [], 'consistent_snapshot': False}
    try:
        # TemporaryDirectory é privada (0700); nenhum segredo sai no terminal.
        with tempfile.TemporaryDirectory(prefix='baixas-backup-') as tmp:
            root = Path(tmp)
            subprocess.run(['pg_dump', '--format=custom', '--no-owner', '--no-acl', '--file', str(root / 'database.dump')],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            (root / 'objects').mkdir()
            buckets = json_api('/storage/v1/bucket')
            for bucket in buckets:
                bucket_id = bucket['id']
                pending = ['']
                while pending:
                    prefix = pending.pop()
                    offset = 0
                    while True:
                        rows = json_api('/storage/v1/object/list/' + quote(bucket_id, safe=''),
                                        {'prefix': prefix, 'limit': 100, 'offset': offset, 'sortBy': {'column': 'name', 'order': 'asc'}})
                        for row in rows:
                            object_name = (prefix + '/' if prefix else '') + row['name']
                            if row.get('id') is None:
                                pending.append(object_name)
                                continue
                            # Nomes remotos são metadados; nunca são caminhos locais.
                            filename = 'objects/' + str(len(manifest['objects']))
                            digest = hashlib.sha256()
                            size = 0
                            with api('/storage/v1/object/' + quote(bucket_id, safe='') + '/' + quote(object_name, safe='/')) as response, (root / filename).open('xb') as target:
                                while block := response.read(1024 * 1024):
                                    digest.update(block)
                                    size += len(block)
                                    target.write(block)
                            manifest['objects'].append({'bucket': bucket_id, 'name': object_name, 'file': filename,
                                                        'sha256': digest.hexdigest(), 'bytes': size})
                        if len(rows) < 100:
                            break
                        offset += len(rows)
            manifest['buckets'] = buckets
            manifest['finished_at'] = datetime.now(timezone.utc).isoformat()
            manifest['database_sha256'] = file_hash(root / 'database.dump')
            (root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
            archive = root / 'backup.tar'
            with tarfile.open(archive, 'w') as tar:
                for entry in ['database.dump', 'manifest.json', 'objects']:
                    tar.add(root / entry, arcname=entry)
            subprocess.run(['gpg', '--batch', '--yes', '--trust-model', 'always', '--encrypt',
                            '--recipient', os.environ['BACKUP_GPG_RECIPIENT'], '--output', str(partial), str(archive)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            os.chmod(partial, 0o600)
            partial.rename(output)
        digest = file_hash(output)
        try:
            json_api('/rest/v1/rpc/register_retention_backup', {'p_name': name, 'p_sha256': digest,
                'p_created_at': created.isoformat(), 'p_scope': 'banco_e_storage'})
        except (HTTPError, URLError, TimeoutError):
            # Backup pronto é preservado mesmo se o registro falhar.
            print('Backup cifrado preservado, mas o inventário falhou. Não repita a geração para registrar a mesma cópia.')
            print(json.dumps({'p_name': name, 'p_sha256': digest, 'p_created_at': created.isoformat(), 'p_scope': 'banco_e_storage'}))
            return 2
        print('Backup cifrado gerado e registrado: ' + name)
        print('Guardar até: ' + ten_years(created).isoformat() + '. Verifique a cópia externa e teste a restauração.')
        return 0
    finally:
        partial.unlink(missing_ok=True)


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.CalledProcessError):
        # Não imprimir exceções HTTP/PG: podem incluir dados internos ou credenciais.
        print('Backup não concluído. Confira a configuração, o acesso ao banco/Storage, o espaço e a chave pública GPG. Nenhuma cópia anterior foi apagada.')
        raise SystemExit(1)
