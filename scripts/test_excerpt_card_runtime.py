#!/usr/bin/env python3
"""Exercise synthetic excerpt rendering in a packaged KOReader installation."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from mock_weread import prepare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--run-dir', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    args = parser.parse_args()
    root, runtime = args.run_dir.resolve(), args.koreader.resolve()
    prepare(root, runtime, 8765, args.width, args.height, args.dpi)
    (root / 'xdg').mkdir(mode=0o700)
    evidence = root / 'evidence'
    env = os.environ | dict(KO_HOME=str(root/'profile'), XDG_RUNTIME_DIR=str(root/'xdg'),
        EMULATE_READER='1', EMULATE_READER_W=str(args.width), EMULATE_READER_H=str(args.height),
        EMULATE_READER_DPI=str(args.dpi), EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
        WEREAD_EXCERPT_EVIDENCE=str(evidence))
    probe = Path(__file__).resolve().parent.parent/'spec/koreader/excerpt_card_probe.lua'
    log = evidence/'excerpt.log'
    with log.open('w') as output:
        child = subprocess.run([str(runtime/'luajit'), str(probe)], cwd=runtime, env=env,
                               stdout=output, stderr=subprocess.STDOUT, timeout=120)
    raw = log.read_bytes()
    marker = b'\nWEREAD_EXCERPT='
    if child.returncode or raw.count(marker) != 1:
        raise ValueError('excerpt renderer failed; inspect synthetic log')
    result = json.loads(raw.split(marker, 1)[1].splitlines()[0])
    if result != {'result': 'PASS', 'images': 12}:
        raise ValueError('excerpt renderer result mismatch')
    for path in evidence.glob('excerpt-*.png'):
        if not path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'):
            raise ValueError('invalid synthetic PNG')
    if len(list(evidence.glob('excerpt-*.png'))) != 12:
        raise ValueError('missing synthetic PNG')
    print(json.dumps({'result': 'PASS', 'width': args.width, 'height': args.height, 'images': 12}))


if __name__ == '__main__':
    main()
