#!/usr/bin/env python3
"""Compare synthetic home summary reads in packaged KOReader."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_HOME_SUMMARY_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='df54db1ad32b7c38eee92a7941fe78db3d99ecc8')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    result = {}
    with tempfile.TemporaryDirectory(prefix='weread-home-summary-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        archive = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(archive)],
                       check=True, capture_output=True)
        for kind in ('short', 'long'):
            result[kind] = {}
            for mode in ('baseline', 'optimized'):
                profile = root / f'{kind}-{mode}'
                (profile / 'plugins').mkdir(parents=True)
                xdg = root / f'xdg-{kind}-{mode}'
                xdg.mkdir(mode=0o700)
                extract_candidate(archive, profile / 'plugins')
                plugin = profile / 'plugins/weread.koplugin'
                if mode == 'baseline':
                    for relative in ('weread/lib/library_db.lua', 'weread/lib/profile.lua', 'weread/ui/home_settings.lua'):
                        (plugin / relative).write_bytes(subprocess.run(['git', 'show', args.baseline_ref + ':' + relative],
                            cwd=repo, check=True, capture_output=True).stdout)
                samples = []
                for _ in range(3):
                    code, output, repaint = run_child([str(runtime / 'luajit'),
                        str(repo / 'spec/koreader/home_summary_benchmark.lua'), kind],
                        dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg),
                             SDL_VIDEODRIVER='dummy', EMULATE_READER='1'), b'', runtime, timeout=120)
                    if code or repaint or output.count(FRAME) != 1:
                        raise ValueError('home summary benchmark failed')
                    row = json.loads(output.split(FRAME)[1])
                    if (row['result'] != 'PASS' or row['calls'] != 100 or not row['goal_update_visible']
                            or row['read_opens'] != (200 if mode == 'baseline' else 100)):
                        raise ValueError('home summary verification failed')
                    samples.append(row)
                result[kind][mode] = {'samples': samples,
                    'median_seconds': statistics.median(row['seconds'] for row in samples),
                    'median_wall_seconds': statistics.median(row['wall_seconds'] for row in samples)}
            if result[kind]['baseline']['samples'][0]['summary'] != result[kind]['optimized']['samples'][0]['summary']:
                raise ValueError('home summary changed')
    print(json.dumps({'cases': result, 'summary_equal': True}))


if __name__ == '__main__':
    main()
