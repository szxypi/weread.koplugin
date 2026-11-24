#!/usr/bin/env python3
"""Compare synthetic progress repaint counts and images in packaged KOReader."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from PIL import Image, ImageChops
from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_PROGRESS_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='f6203ec6542798c4e2ea427e3390c8fab6a60ca2')
    parser.add_argument('--debug-dir', type=Path, help='Keep synthetic images for visual comparison')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-progress-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        candidate = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        old = root / 'download_dialog_old.lua'
        old.write_bytes(subprocess.run(['git', 'show', args.baseline_ref + ':weread/ui/download_dialog.lua'],
                                       cwd=repo, check=True, capture_output=True).stdout)
        result = {}
        pixel_differences = {}
        for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
            results, shots = {}, {}
            for mode in ('baseline', 'optimized'):
                profile = root / f'profile-{width}-{mode}'
                (profile / 'plugins').mkdir(parents=True)
                xdg = root / f'xdg-{width}-{mode}'
                xdg.mkdir(mode=0o700)
                extract_candidate(candidate, profile / 'plugins')
                shots[mode] = root / f'shots-{width}-{mode}'
                shots[mode].mkdir()
                env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), SDL_VIDEODRIVER='dummy',
                           EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                           EMULATE_READER_W=str(width), EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi),
                           WEREAD_PROGRESS_SHOTS=str(shots[mode]))
                code, output, repaint = run_child([str(runtime / 'luajit'),
                    str(repo / 'spec/koreader/download_progress_benchmark.lua'), mode, str(old)], env, b'', runtime, timeout=150)
                if code or repaint or output.count(FRAME) != 1:
                    raise ValueError('progress benchmark failed')
                results[mode] = json.loads(output.split(FRAME)[1])
                if results[mode]['result'] != 'PASS' or not results[mode]['cancel_safe']:
                    raise ValueError('progress verification failed')
            for name in ('middle.png', 'complete.png'):
                if args.debug_dir:
                    args.debug_dir.mkdir(parents=True, exist_ok=True)
                    for mode in ('baseline', 'optimized'):
                        shutil.copy2(shots[mode] / name, args.debug_dir / f'{width}-{mode}-{name}')
                with Image.open(shots['baseline'] / name) as first, Image.open(shots['optimized'] / name) as second:
                    before, after = first.convert('RGB'), second.convert('RGB')
                    if before.size != (width, height) or before.size != after.size:
                        raise ValueError('progress screenshot dimensions changed')
                    frame = ImageChops.invert(before).getbbox()
                    if not frame or frame != ImageChops.invert(after).getbbox():
                        raise ValueError('progress frame bounds changed')
                    difference = ImageChops.difference(before, after)
                    pixels = difference.load()
                    left, top, right, bottom = frame
                    corner = max(12, round(width * 16 / 600))
                    changed = 0
                    for y in range(top, bottom):
                        for x in range(left, right):
                            if pixels[x, y] != (0, 0, 0):
                                changed += 1
                                if not ((x < left + corner or x >= right - corner)
                                        and (y < top + corner or y >= bottom - corner)):
                                    raise ValueError('progress content pixels changed')
                    if changed > (128 if width == 600 else 256):
                        raise ValueError('too many rounded corner pixels changed')
                    pixel_differences[f'{width}-{name}'] = changed
            result[str(width)] = results
        print(json.dumps({'cases': result, 'content_pixels_identical': True,
                          'rounded_corner_pixels_changed': pixel_differences, 'synthetic_updates': 100}))


if __name__ == '__main__':
    main()
