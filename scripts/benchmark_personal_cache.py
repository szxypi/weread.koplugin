#!/usr/bin/env python3
"""Compare personal-note SQLite cache writes using only synthetic data."""
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
    parser.add_argument('--baseline', default='605f68a3')
    parser.add_argument('--runs', type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.runs <= 5:
        parser.error('--runs must be between 1 and 5')
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    source = subprocess.check_output(['git', 'show', f'{args.baseline}:weread/lib/my_cloud_marks_store.lua'], cwd=repo)
    with tempfile.TemporaryDirectory(prefix='weread-personal-cache-bench-', dir='/dev/shm') as directory:
        root = Path(directory)
        baseline = root / 'baseline.lua'
        baseline.write_bytes(source)
        candidate = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], cwd=repo,
                       check=True, capture_output=True)
        (root / 'plugins').mkdir()
        extract_candidate(candidate, root / 'plugins')
        plugin = root / 'plugins/weread.koplugin'
        env = dict(os.environ, LD_LIBRARY_PATH=str(runtime / 'libs'))
        results = []
        for index in range(args.runs):
            work = root / f'run-{index}'
            work.mkdir()
            child = subprocess.run([str(runtime / 'luajit'), str(repo / 'spec/koreader/personal_cache_fast_path_probe.lua'),
                                    str(plugin), str(baseline), str(work)], cwd=runtime, env=env,
                                   capture_output=True, text=True, timeout=240)
            lines = [line for line in child.stdout.splitlines() if line.startswith('WEREAD_PERSONAL_CACHE_BENCHMARK=')]
            if child.returncode or len(lines) != 1:
                raise RuntimeError(f'benchmark failed: {child.stdout[-1000:]} {child.stderr[-1000:]}')
            result = json.loads(lines[0].split('=', 1)[1])
            if result['result'] != 'PASS' or result['differential_operations'] != 240:
                raise ValueError('benchmark or differential comparison failed')
            results.append(result['measurements'])
        summary = []
        for index, first in enumerate(results[0]):
            samples = [run[index] for run in results]
            assert all(row['variant'] == first['variant'] and row['books'] == first['books'] for row in samples)
            summary.append({'variant': first['variant'], 'books': first['books'], 'iterations': first['iterations'],
                            'old_cpu_ms_median': round(statistics.median(row['old']['cpu_ms'] for row in samples), 1),
                            'new_cpu_ms_median': round(statistics.median(row['new']['cpu_ms'] for row in samples), 1),
                            'old_ordered_row_steps': first['old']['ordered_row_steps'],
                            'new_ordered_row_steps': first['new']['ordered_row_steps']})
        print(json.dumps({'result': 'PASS', 'synthetic_only': True, 'baseline': args.baseline,
                          'runs': args.runs, 'differential_operations_per_run': 240, 'measurements': summary}))


if __name__ == '__main__':
    main()
