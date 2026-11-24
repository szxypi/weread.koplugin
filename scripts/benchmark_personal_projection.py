#!/usr/bin/env python3
"""Measure synthetic note validation and SQLite persistence in KOReader."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.runs <= 5:
        parser.error('--runs must be between 1 and 5')
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-personal-projection-', dir='/dev/shm') as directory:
        root = Path(directory)
        candidate = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], cwd=repo,
                       check=True, capture_output=True)
        (root / 'plugins').mkdir()
        extract_candidate(candidate, root / 'plugins')
        env = dict(os.environ, LD_LIBRARY_PATH=str(runtime / 'libs'))
        runs = []
        for index in range(args.runs):
            work = root / f'run-{index}'
            work.mkdir()
            child = subprocess.run([str(runtime / 'luajit'), str(repo / 'spec/koreader/personal_cache_projection_probe.lua'),
                                    str(root / 'plugins/weread.koplugin'), str(work)], cwd=runtime, env=env,
                                   capture_output=True, text=True, timeout=240)
            lines = [line for line in child.stdout.splitlines() if line.startswith('WEREAD_PERSONAL_PROJECTION_BENCHMARK=')]
            if child.returncode or len(lines) != 1:
                raise RuntimeError(f'benchmark failed: {child.stdout[-1000:]} {child.stderr[-1000:]}')
            result = json.loads(lines[0].split('=', 1)[1])
            if result['result'] != 'PASS':
                raise ValueError('projection comparison failed')
            runs.append(result['measurements'])
        summary = []
        for index, first in enumerate(runs[0]):
            values = [run[index] for run in runs]
            assert all(row['variant'] == first['variant'] and row['notes'] == first['notes'] for row in values)
            summary.append({'variant': first['variant'], 'notes': first['notes'], 'iterations': first['iterations'],
                            'old_cpu_ms_median': round(statistics.median(row['old']['cpu_ms'] for row in values), 1),
                            'new_cpu_ms_median': round(statistics.median(row['new']['cpu_ms'] for row in values), 1),
                            'old_validation_calls': first['old']['validation_calls'],
                            'new_validation_calls': first['new']['validation_calls']})
        print(json.dumps({'result': 'PASS', 'synthetic_only': True, 'runs': args.runs, 'measurements': summary}))


if __name__ == '__main__':
    main()
