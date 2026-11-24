#!/usr/bin/env python3
"""Compare position anchors with the previous implementation using synthetic chapters."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_ANCHOR_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='e6fc3d11dac801a534e6ec9d35e248ac8a8f47c0')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-anchor-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        profile = root / 'profile'
        (profile / 'plugins').mkdir(parents=True)
        candidate = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        extract_candidate(candidate, profile / 'plugins')
        old = root / 'source_coordinates_old.lua'
        old.write_bytes(subprocess.run(['git', 'show', args.baseline_ref + ':weread/lib/source_coordinates.lua'],
                                       cwd=repo, check=True, capture_output=True).stdout)
        env = dict(os.environ, KO_HOME=str(profile))
        code, output, repaint = run_child([str(runtime / 'luajit'), str(repo / 'spec/koreader/anchor_benchmark.lua'),
                                          str(profile / 'plugins/weread.koplugin'), str(old)],
                                         env, b'', runtime, timeout=180)
        if code or repaint or output.count(FRAME) != 1:
            raise ValueError('anchor benchmark failed')
        result = json.loads(output.split(FRAME)[1])
        if result['comparisons'] < 2000:
            raise ValueError('too few differential cases')
        print(json.dumps(result))


if __name__ == '__main__':
    main()
