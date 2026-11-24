#!/usr/bin/env python3
"""Compare batched highlight indexing in packaged KOReader using synthetic text."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='8717e08f')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    baseline = subprocess.check_output(['git', 'show', args.baseline_ref + ':weread/ui/xpointer_overlay.lua'], cwd=repo)
    reports = {}
    with tempfile.TemporaryDirectory(prefix='weread-overlay-index-', dir='/dev/shm') as directory:
        root = Path(directory)
        old = root / 'baseline.lua'
        old.write_bytes(baseline)
        for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
            run = root / str(width)
            env = dict(os.environ, SDL_VIDEODRIVER='dummy', LD_LIBRARY_PATH=str(runtime / 'libs'),
                       WEREAD_OVERLAY_INDEX_ONLY='1', WEREAD_OVERLAY_BASELINE=str(old))
            result = subprocess.run(['python3', str(repo / 'scripts/test_position_runtime.py'), '--koreader', str(runtime),
                '--run-dir', str(run), '--probe', 'source-dom', '--width', str(width), '--height', str(height),
                '--dpi', str(dpi)], cwd=repo, env=env, capture_output=True, text=True, timeout=180)
            if result.returncode:
                log = run / 'evidence/runtime.log'
                raise RuntimeError('synthetic reader failed: ' + (log.read_text(errors='replace')[:2000] if log.exists() else result.stderr[-1000:]))
            report = json.loads((run / 'evidence/overlay-index.json').read_text())
            if report['records'] != 320 or report['batches'] != 40:
                raise ValueError('unexpected synthetic fixture')
            reports[str(width)] = report
    print(json.dumps({'result': 'PASS', 'synthetic_only': True, 'baseline': args.baseline_ref, 'sizes': reports}))


if __name__ == '__main__':
    main()
