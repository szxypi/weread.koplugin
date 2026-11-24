#!/usr/bin/env python3
"""Compare personal-mark anchor preparation using synthetic chapters."""
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
    parser.add_argument('--baseline', default='14e062d2')
    parser.add_argument('--runs', type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.runs <= 5:
        parser.error('--runs must be between 1 and 5')
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    source = subprocess.check_output(['git', 'show', f'{args.baseline}:weread/lib/my_mark_span.lua'], cwd=repo)
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
            child = subprocess.run([str(runtime / 'luajit'), str(repo / 'spec/koreader/personal_mark_batch_probe.lua'),
                                    str(plugin), str(baseline)], cwd=runtime, env=env,
                                   capture_output=True, text=True, timeout=240)
            lines = [line for line in child.stdout.splitlines() if line.startswith('WEREAD_PERSONAL_MARK_BATCH=')]
            if child.returncode or len(lines) != 1:
                raise RuntimeError(f'benchmark failed: {child.stdout[-1000:]} {child.stderr[-1000:]}')
            result = json.loads(lines[0].split('=', 1)[1])
            if (result['result'] != 'PASS' or result['comparisons'] < 300
                    or result['old_map_builds'] != 16 or result['new_map_builds'] != 1):
                raise ValueError('benchmark or differential comparison failed')
            results.append(result)
        first = results[0]
        print(json.dumps({'result': 'PASS', 'synthetic_only': True, 'baseline': args.baseline,
                          'runs': args.runs, 'comparisons_per_run': first['comparisons'],
                          'chapter_bytes': first['chapter_bytes'], 'highlights': first['highlights'],
                          'iterations': first['iterations'], 'old_map_builds': first['old_map_builds'],
                          'new_map_builds': first['new_map_builds'],
                          'old_cpu_ms_median': round(statistics.median(r['old_cpu_ms'] for r in results), 1),
                          'new_cpu_ms_median': round(statistics.median(r['new_cpu_ms'] for r in results), 1)}))


if __name__ == '__main__':
    main()
