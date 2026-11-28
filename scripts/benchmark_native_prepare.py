#!/usr/bin/env python3
"""Compare native chapter resource preparation with the previous implementation."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_NATIVE_PREPARE_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='1ef46ada086107aae6feaf0dde6194a58295ef3d')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-prepare-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        profile = root / 'profile'
        (profile / 'plugins').mkdir(parents=True)
        candidate = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        extract_candidate(candidate, profile / 'plugins')
        old = root / 'native_chapter_remote_old.lua'
        old.write_bytes(subprocess.run(['git', 'show', args.baseline_ref + ':weread/lib/native_chapter_remote.lua'],
                                       cwd=repo, check=True, capture_output=True).stdout)
        env = dict(os.environ, KO_HOME=str(profile))
        code, output, repaint = run_child([str(runtime / 'luajit'), str(repo / 'spec/koreader/native_prepare_benchmark.lua'),
                                          str(profile / 'plugins/weread.koplugin'), str(old)],
                                         env, b'', runtime, timeout=180)
        if code or repaint or output.count(FRAME) != 1:
            raise ValueError('native chapter preparation benchmark failed')
        print(json.dumps(json.loads(output.split(FRAME)[1])))


if __name__ == '__main__':
    main()
