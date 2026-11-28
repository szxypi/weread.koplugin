#!/usr/bin/env python3
"""Compare packaged native ZIP processing with its former CRC implementation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_NATIVE_ARCHIVE_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='93b1b84e7c9350a658376ccdb4f33aced3786cb4')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-native-archive-', dir='/dev/shm') as temp:
        root = Path(temp)
        profile = root / 'profile'
        (profile / 'plugins').mkdir(parents=True)
        candidate = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        extract_candidate(candidate, profile / 'plugins')
        plugin = profile / 'plugins' / 'weread.koplugin'
        baseline = root / 'baseline'
        shutil.copytree(plugin, baseline)
        original = subprocess.run(['git', 'show', args.baseline_ref + ':weread/lib/native_chapter_archive.lua'],
                                  cwd=repo, check=True, capture_output=True).stdout
        (baseline / 'weread/lib/native_chapter_archive.lua').write_bytes(original)
        fixture = root / 'fixture'
        fixture.mkdir()
        body = b'<p>' + b'synthetic chapter text ' * 2000 + b'</p>'
        image = b'\x89PNG\r\n\x1a\n' + hashlib.shake_256(b'synthetic image').digest(2 * 1024 * 1024)
        (fixture / '37.html').write_bytes(body)
        (fixture / 'image.png').write_bytes(image)
        result = {}
        for kind in ('plain', 'encrypted'):
            target = root / (kind + '.zip')
            command = ['zip', '-q', '-0']
            if kind == 'encrypted':
                command += ['-P', 'test-password']
            subprocess.run(command + [str(target), '37.html', 'image.png'], cwd=fixture, check=True)
            samples = {}
            for mode in ('baseline', 'optimized'):
                times = []
                for _ in range(3):
                    env = dict(os.environ, KO_HOME=str(profile))
                    code, output, repaint = run_child([str(runtime / 'luajit'),
                        str(repo / 'spec/koreader/native_archive_benchmark.lua'),
                        str(baseline if mode == 'baseline' else plugin), str(target), mode],
                        env, b'', runtime, timeout=120)
                    if code or repaint or output.count(FRAME) != 1:
                        raise ValueError('native archive benchmark failed')
                    row = json.loads(output.split(FRAME)[1])
                    if (row['body_sha256'] != hashlib.sha256(body).hexdigest()
                            or row['image_sha256'] != hashlib.sha256(image).hexdigest()
                            or (mode == 'optimized' and row['backend_calls'] < 9)):
                        raise ValueError('native archive verification failed')
                    times.append(row['seconds'])
                samples[mode] = {'seconds': times, 'median_seconds': statistics.median(times)}
            result[kind] = samples
        print(json.dumps({'image_bytes': len(image), 'reads_per_run': 3, 'runs': 3, 'cases': result}))


if __name__ == '__main__':
    main()
