#!/usr/bin/env python3
"""Check packaged SHA-256 and MD5 paths against hashlib using synthetic inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_SHA256_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-sha-', dir='/dev/shm') as directory:
        profile = Path(directory) / 'profile'
        (profile / 'plugins').mkdir(parents=True)
        candidate = Path(directory) / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        extract_candidate(candidate, profile / 'plugins')
        env = dict(os.environ, KO_HOME=str(profile))
        code, output, repaint = run_child([str(runtime / 'luajit'), str(repo / 'spec/koreader/sha256_benchmark.lua')],
                                          env, b'', runtime, timeout=150)
        if output.count(FRAME) != 1:
            raise ValueError('benchmark result missing')
        result = json.loads(output.split(FRAME)[1])
        if (code or repaint or result['result'] != 'PASS' or not result['backend_selected'] or not result['native_backend_selected']
                or not result['md5_backend_selected'] or not result['existing_cover_cache_key_verified']):
            raise ValueError(f'benchmark failed: {result}')
        for row in result['vectors']:
            size = row['bytes']
            pattern = bytes((i*73+19+row['seed']*31)%256 for i in range(256))
            data = (pattern * ((size+255)//256))[:size]
            if row['digest'] != hashlib.sha256(data).hexdigest():
                raise ValueError(f'digest mismatch at {size} bytes')
            if row['md5'] != hashlib.md5(data).hexdigest():
                raise ValueError(f'MD5 mismatch at {size} bytes')
        print(json.dumps(result))


if __name__ == '__main__':
    main()
