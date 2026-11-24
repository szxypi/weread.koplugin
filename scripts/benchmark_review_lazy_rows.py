#!/usr/bin/env python3
"""Compare packaged review rows with a previous revision, using synthetic data."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import zipfile

from PIL import Image, ImageChops


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='fcc3d3d8')
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--rtl', action='store_true')
    parser.add_argument('--no-xtext', action='store_true')
    args = parser.parse_args()
    if not 1 <= args.runs <= 5:
        parser.error('--runs must be between 1 and 5')
    repo = Path(__file__).resolve().parent.parent
    baseline = subprocess.check_output(['git', 'show', args.baseline_ref + ':weread/ui/book_reviews_view.lua'], cwd=repo)
    reports = {}
    with tempfile.TemporaryDirectory(prefix='weread-review-compare-', dir='/dev/shm') as directory:
        root = Path(directory)
        candidate, old = root / 'candidate.zip', root / 'baseline.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        target = 'weread.koplugin/weread/ui/book_reviews_view.lua'
        with zipfile.ZipFile(candidate) as source, zipfile.ZipFile(old, 'w') as destination:
            assert target in source.namelist()
            for entry in source.infolist():
                destination.writestr(entry, baseline if entry.filename == target else source.read(entry))
        for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
            samples = {'old': [], 'new': []}
            for run in range(args.runs):
                images = {}
                for name, archive in (('old', old), ('new', candidate)):
                    shots = root / f'{width}-{run}-{name}'
                    images[name] = shots
                    cmd = ['python3', str(repo / 'scripts/benchmark_review_list.py'), '--koreader', str(args.koreader),
                           '--candidate', str(archive), '--screenshots', str(shots), '--width', str(width),
                           '--height', str(height), '--dpi', str(dpi)]
                    if args.rtl:
                        cmd.append('--rtl')
                    if args.no_xtext:
                        cmd.append('--no-xtext')
                    result = subprocess.run(cmd, cwd=repo, env=os.environ, capture_output=True, text=True, timeout=180)
                    if result.returncode:
                        raise RuntimeError(f'{name} benchmark failed: {result.stderr[-2000:]}')
                    samples[name].append(json.loads(result.stdout))
                previous, current = samples['old'][-1], samples['new'][-1]
                if (previous['initial_materialized'] != 201 or current['max_materialized'] > 20
                        or any(previous[key] != current[key] for key in ('width_checksum', 'height_checksum'))):
                    raise ValueError('row count or geometry differs')
                for i in range(1, 5):
                    with Image.open(images['old'] / f'optimized-{i}.png') as a, Image.open(images['new'] / f'optimized-{i}.png') as b:
                        if a.size != b.size or ImageChops.difference(a.convert('RGB'), b.convert('RGB')).getbbox():
                            raise ValueError(f'frame differs: {width}, {run}, {i}')
            reports[str(width)] = {
                name: {key: statistics.median(item[key] for item in rows)
                       for key in ('initial_cpu_ms', 'initial_lua_kib', 'initial_materialized', 'max_materialized')}
                for name, rows in samples.items()
            }
    print(json.dumps({'result': 'PASS', 'runs': args.runs, 'rtl': args.rtl, 'no_xtext': args.no_xtext,
                      'pixel_pairs': 8 * args.runs, 'sizes': reports}))


if __name__ == '__main__':
    main()
