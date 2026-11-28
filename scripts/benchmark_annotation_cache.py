#!/usr/bin/env python3
"""Measure retained quote-cache memory with many synthetic source spans."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_ANNOTATION_CACHE_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='8b7ebf4fd89b7b10430f772e32760c75fae4f52c')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-annotation-cache-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        profile = root / 'profile'
        (profile / 'plugins').mkdir(parents=True)
        archive = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(archive)],
                       check=True, capture_output=True)
        extract_candidate(archive, profile / 'plugins')
        baseline = root / 'annotation_source_old.lua'
        baseline.write_bytes(subprocess.run(['git', 'show',
            args.baseline_ref + ':weread/lib/annotation_source.lua'], cwd=repo,
            check=True, capture_output=True).stdout)
        code, output, repaint = run_child([str(runtime / 'luajit'),
            str(repo / 'spec/koreader/annotation_cache_budget_benchmark.lua'),
            str(profile / 'plugins/weread.koplugin'), str(baseline)],
            dict(os.environ, KO_HOME=str(profile)), b'', runtime, timeout=180)
        if code or repaint or output.count(FRAME) != 1:
            raise ValueError('annotation cache benchmark failed')
        result = json.loads(output.split(FRAME)[1])
        print(json.dumps(result))


if __name__ == '__main__':
    main()
