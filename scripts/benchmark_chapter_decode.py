#!/usr/bin/env python3
"""Benchmark packaged chapter decoding using synthetic shards in tmpfs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from mock_weread import shards
from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_CHAPTER_DECODE_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--candidate', type=Path)
    parser.add_argument('--repeats', type=int, default=18000)
    parser.add_argument('--iterations', type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.repeats <= 100000 or not 1 <= args.iterations <= 10:
        parser.error('fixture size or iterations out of bounds')
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    text = '合成章节中的正文与标点，mixed English 123，表情🙂。\n' * args.repeats
    expected = text.encode('utf-8')
    with tempfile.TemporaryDirectory(prefix='weread-chapter-decode-', dir='/dev/shm') as directory:
        root = Path(directory)
        profile = root / 'profile'
        (profile / 'plugins').mkdir(parents=True)
        candidate = args.candidate.resolve() if args.candidate else root / 'candidate.zip'
        if not args.candidate:
            subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        extract_candidate(candidate, profile / 'plugins')
        for name, payload in zip(('e0', 'e1', 'e3'), shards(text)):
            (root / name).write_bytes(payload.encode('ascii'))
        env = dict(os.environ, KO_HOME=str(profile), WEREAD_DECODE_FIXTURE=str(root),
                   WEREAD_DECODE_ITERATIONS=str(args.iterations))
        code, output, repaint = run_child([str(runtime / 'luajit'), str(repo / 'spec/koreader/chapter_decode_benchmark.lua')],
                                          env, b'', runtime, timeout=150)
        if output.count(FRAME) != 1:
            raise ValueError('benchmark result missing')
        result = json.loads(output.split(FRAME)[1])
        if (code or repaint or result['result'] != 'PASS' or result['output_bytes'] != len(expected)
                or result['digest'] != hashlib.sha256(expected).hexdigest()):
            raise ValueError(f'benchmark failed: {result}')
        print(json.dumps(result))


if __name__ == '__main__':
    main()
