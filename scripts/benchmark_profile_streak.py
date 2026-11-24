#!/usr/bin/env python3
"""Compare synthetic reading streaks and monthly fetch preparation."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_PROFILE_STREAK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='cc8d28b34cc9b12d585c5451c62165e3ab019989')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-streak-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        profile = root / 'profile'
        (profile / 'plugins').mkdir(parents=True)
        archive = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(archive)],
                       check=True, capture_output=True)
        extract_candidate(archive, profile / 'plugins')
        baseline = root / 'profile_old.lua'
        baseline.write_bytes(subprocess.run(['git', 'show', args.baseline_ref + ':weread/lib/profile.lua'],
                                           cwd=repo, check=True, capture_output=True).stdout)
        samples = []
        for _ in range(3):
            code, output, repaint = run_child([str(runtime / 'luajit'),
                str(repo / 'spec/koreader/profile_streak_benchmark.lua'),
                str(profile / 'plugins/weread.koplugin'), str(baseline)],
                dict(os.environ, KO_HOME=str(profile)), b'', runtime, timeout=120)
            if code or repaint or output.count(FRAME) != 1:
                raise ValueError('profile streak benchmark failed')
            row = json.loads(output.split(FRAME)[1])
            if row['result'] != 'PASS' or row['fetch']['optimized']['requests'] != 24:
                raise ValueError('profile streak verification failed')
            samples.append(row)
        medians = {}
        for case in ('two_years', 'maximum'):
            medians[case] = {mode: statistics.median(s['cases'][mode][case]['seconds'] for s in samples)
                             for mode in ('baseline', 'optimized')}
        medians['fetch'] = {mode: statistics.median(s['fetch'][mode]['seconds'] for s in samples)
                            for mode in ('baseline', 'optimized')}
        print(json.dumps({'samples': samples, 'median_seconds': medians}))


if __name__ == '__main__':
    main()
