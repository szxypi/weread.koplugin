#!/usr/bin/env python3
"""Compare source-position work on synthetic page changes without network access."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_SOURCE_PAGE_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='fc98016a')
    parser.add_argument('--runs', type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.runs <= 5:
        parser.error('--runs must be between 1 and 5')
    repo, runtime = Path(__file__).resolve().parent.parent, args.koreader.resolve()
    baseline = subprocess.check_output(['git', 'show', args.baseline_ref + ':weread/lib/source_position.lua'], cwd=repo)
    reports = {}
    with tempfile.TemporaryDirectory(prefix='weread-source-page-', dir='/dev/shm') as directory:
        root = Path(directory)
        archive = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(archive)], check=True, capture_output=True)
        for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
            results = {'old': [], 'new': []}
            for variant in ('old', 'new'):
                for index in range(args.runs):
                    profile = root / f'{width}-{variant}-{index}'
                    (profile / 'plugins').mkdir(parents=True)
                    extract_candidate(archive, profile / 'plugins')
                    if variant == 'old':
                        (profile / 'plugins/weread.koplugin/weread/lib/source_position.lua').write_bytes(baseline)
                    xdg = root / f'xdg-{width}-{variant}-{index}'
                    xdg.mkdir(mode=0o700)
                    env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), SDL_VIDEODRIVER='dummy',
                               EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                               EMULATE_READER_W=str(width), EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi))
                    code, output, repaint = run_child([str(runtime / 'luajit'),
                        str(repo / 'spec/koreader/source_page_update_benchmark.lua')], env, b'', runtime, timeout=90)
                    if code or repaint or output.count(FRAME) != 1:
                        raise ValueError('page update benchmark failed')
                    result = json.loads(output.split(FRAME)[1].splitlines()[0])
                    if result['result'] != 'PASS' or result['unchanged']['calls'] != 2000:
                        raise ValueError('unchanged view did not retain full recheck')
                    expected = 2000 if variant == 'old' else 1000
                    if result['changed']['calls'] != expected:
                        raise ValueError('unexpected location capture count')
                    results[variant].append(result)
            reports[str(width)] = {variant: {
                'changed_calls': rows[0]['changed']['calls'],
                'unchanged_calls': rows[0]['unchanged']['calls'],
                'changed_cpu_ms': round(statistics.median(row['changed']['cpu_ms'] for row in rows), 2),
                'unchanged_cpu_ms': round(statistics.median(row['unchanged']['cpu_ms'] for row in rows), 2),
            } for variant, rows in results.items()}
    print(json.dumps({'result': 'PASS', 'runs': args.runs, 'events_per_case': 1000, 'sizes': reports}))


if __name__ == '__main__':
    main()
