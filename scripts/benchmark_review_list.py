#!/usr/bin/env python3
"""Compare synthetic review-list painting and screenshots without an account."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from PIL import Image, ImageChops
from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_REVIEW_LIST_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--width', type=int, default=1264)
    parser.add_argument('--height', type=int, default=1680)
    parser.add_argument('--dpi', type=int, default=300)
    parser.add_argument('--rtl', action='store_true')
    parser.add_argument('--no-xtext', action='store_true')
    parser.add_argument('--flash-ui', action='store_true', help='Exercise native flashing press feedback')
    parser.add_argument('--check-prepaint-press', action='store_true')
    parser.add_argument('--max-initial-previews', type=int)
    parser.add_argument('--max-row-layout-updates', type=int)
    parser.add_argument('--candidate', type=Path, help='Use an existing packaged plugin')
    parser.add_argument('--screenshots', type=Path, help='Save synthetic frames for comparison')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-review-list-', dir='/dev/shm') as directory:
        root = Path(directory)
        profile, xdg, shots = root / 'profile', root / 'xdg', root / 'shots'
        (profile / 'plugins').mkdir(parents=True)
        xdg.mkdir(mode=0o700)
        shots.mkdir()
        candidate = args.candidate.resolve() if args.candidate else root / 'candidate.zip'
        if not args.candidate:
            subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        extract_candidate(candidate, profile / 'plugins')
        env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), EMULATE_READER='1',
                   EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(args.width),
                   EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi),
                   WEREAD_REVIEW_SHOTS=str(shots), WEREAD_REVIEW_RTL='1' if args.rtl else '0',
                   WEREAD_REVIEW_NO_XTEXT='1' if args.no_xtext else '0',
                   WEREAD_REVIEW_FLASH='1' if args.flash_ui else '0',
                   WEREAD_REVIEW_PREPAINT_PRESS='1' if args.check_prepaint_press else '0')
        code, output, repaint = run_child([str(runtime / 'luajit'), str(repo / 'spec/koreader/eink_review_list_benchmark.lua')],
                                          env, b'', runtime, timeout=150)
        if code or repaint or output.count(FRAME) != 1:
            raise RuntimeError('review benchmark failed: ' + output[-3000:].decode(errors='replace'))
        report = json.loads(output.split(FRAME)[1])
        for index in range(1, report['frames'] + 1):
            with Image.open(shots / f'original-{index}.png') as original, Image.open(shots / f'optimized-{index}.png') as optimized:
                if ImageChops.difference(original.convert('RGB'), optimized.convert('RGB')).getbbox():
                    raise AssertionError(f'frame {index} differs')
        if (report['result'] != 'PASS' or report['original'] != 804 or report['optimized'] >= report['original']
                or report['event_visits'] != 200 or report['original_event_visits'] <= report['event_visits']):
            raise AssertionError(report)
        for limit, field in ((args.max_initial_previews, 'initial_previews'),
                             (args.max_row_layout_updates, 'review_layout_updates')):
            if limit is not None and report[field] > limit:
                raise AssertionError(f'{field} exceeds limit')
        if args.screenshots:
            args.screenshots.mkdir(parents=True, exist_ok=True)
            for frame in shots.glob('*.png'):
                shutil.copyfile(frame, args.screenshots / frame.name)
        print(json.dumps(report))


if __name__ == '__main__':
    main()
