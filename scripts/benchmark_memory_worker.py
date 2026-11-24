#!/usr/bin/env python3
"""Benchmark real KOReader child-process pipes using synthetic data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_WORKER_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='1a8750ed2674ba58cbd485eb536b4cfd87c4efb7')
    parser.add_argument('--size-mib', type=int, default=1, choices=range(1, 9))
    parser.add_argument('--runs', type=int, default=3, choices=range(1, 6))
    parser.add_argument('--candidate-only', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-worker-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        profile = root / 'profile'
        (profile / 'plugins').mkdir(parents=True)
        xdg = root / 'xdg'
        xdg.mkdir(mode=0o700)
        candidate = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        extract_candidate(candidate, profile / 'plugins')
        old = root / 'memory_worker_old.lua'
        old.write_bytes(subprocess.run(['git', 'show', args.baseline_ref + ':weread/lib/memory_worker.lua'],
                                       cwd=repo, check=True, capture_output=True).stdout)
        size = args.size_mib * 1024 * 1024
        pattern = b'Synthetic WeRead worker content 0123456789\n'
        digest = hashlib.sha256((pattern * ((size + len(pattern) - 1) // len(pattern)))[:size]).hexdigest()
        env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), SDL_VIDEODRIVER='dummy',
                   EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                   EMULATE_READER_W='1264', EMULATE_READER_H='1680', EMULATE_READER_DPI='300')
        cases = {}
        for protocol in ('plain', 'stream'):
            cases[protocol] = {}
            for mode in (('optimized',) if args.candidate_only else ('baseline', 'optimized')):
                rows = []
                for _ in range(args.runs):
                    code, output, repaint = run_child([str(runtime / 'luajit'),
                        str(repo / 'spec/koreader/memory_worker_benchmark.lua'), mode, str(old), protocol, str(size)],
                        env, b'', runtime, timeout=40)
                    if code or repaint or output.count(FRAME) != 1:
                        raise ValueError('memory worker benchmark failed')
                    row = json.loads(output.split(FRAME)[1])
                    if row['result'] != 'PASS' or row['bytes'] != size or row['digest'] != digest:
                        raise ValueError('worker output mismatch')
                    rows.append(row)
                cases[protocol][mode] = dict(samples=rows, median_seconds=statistics.median(row['seconds'] for row in rows))
        print(json.dumps({'bytes': size, 'runs_each': args.runs, 'cases': cases}))


if __name__ == '__main__':
    main()
