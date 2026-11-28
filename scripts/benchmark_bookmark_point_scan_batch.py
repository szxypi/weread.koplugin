#!/usr/bin/env python3
"""Compare bookmark source scans using synthetic chapters."""
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
    parser.add_argument('--baseline', default='1985dbc7')
    parser.add_argument('--runs', type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.runs <= 5:
        parser.error('--runs must be between 1 and 5')
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    source = subprocess.check_output(['git', 'show', f'{args.baseline}:weread/lib/bookmark_point.lua'], cwd=repo)
    with tempfile.TemporaryDirectory(prefix='weread-mark-bench-', dir='/dev/shm') as directory:
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
        for _ in range(args.runs):
            child = subprocess.run([str(runtime / 'luajit'), str(repo / 'spec/koreader/bookmark_point_scan_batch_probe.lua'),
                                    str(plugin), str(baseline)], cwd=runtime, env=env,
                                   capture_output=True, text=True, timeout=240)
            lines = [line for line in child.stdout.splitlines() if line.startswith('WEREAD_BOOKMARK_POINT_SCAN_BATCH=')]
            if child.returncode or len(lines) != 1:
                raise RuntimeError(f'benchmark failed: {child.stdout[-1000:]} {child.stderr[-1000:]}')
            result = json.loads(lines[0].split('=', 1)[1])
            if (result['result'] != 'PASS' or result['comparisons'] < 1600
                    or result['old_normalizations'] <= result['new_normalizations'] * 2):
                raise ValueError('benchmark or differential comparison failed')
            results.append(result)
        first = results[0]
        print(json.dumps({'result': 'PASS', 'synthetic_only': True, 'baseline': args.baseline,
                          'runs': args.runs, 'comparisons_per_run': first['comparisons'],
                          'chapter_bytes': first['chapter_bytes'], 'bookmarks': first['bookmarks'],
                          'iterations': first['iterations'], 'old_normalizations': first['old_normalizations'],
                          'new_normalizations': first['new_normalizations'],
                          'old_cpu_ms_median': round(statistics.median(r['old_cpu_ms'] for r in results), 1),
                          'new_cpu_ms_median': round(statistics.median(r['new_cpu_ms'] for r in results), 1),
                          'old_single_cpu_ms_median': round(statistics.median(r['old_single_cpu_ms'] for r in results), 1),
                          'new_single_cpu_ms_median': round(statistics.median(r['new_single_cpu_ms'] for r in results), 1)}))


if __name__ == '__main__':
    main()
