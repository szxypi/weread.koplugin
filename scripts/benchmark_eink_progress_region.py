#!/usr/bin/env python3
"""Compare native progress repaint regions and pixels with synthetic dialogs."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from PIL import Image, ImageChops
from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_PROGRESS_REGION='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='2cd81fe69b371c502bb655c2de5ed5a62f07024e')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-progress-region-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        candidate = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        old = root / 'download_dialog_old.lua'
        old.write_bytes(subprocess.run(['git', 'show', args.baseline_ref + ':weread/ui/download_dialog.lua'],
                                       cwd=repo, check=True, capture_output=True).stdout)
        result = {}
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
                    str(repo / 'spec/koreader/download_progress_region_benchmark.lua'), mode, str(old)],
                    env, b'', runtime, timeout=150)
                if code or repaint or output.count(FRAME) != 1:
                    raise ValueError('progress region benchmark failed')
                results[mode] = json.loads(output.split(FRAME)[1])
                if results[mode]['result'] != 'PASS' or not results[mode]['callback_ok']:
                    raise ValueError('progress region verification failed')
                if mode == 'optimized' and not results[mode]['rotation_fallback']:
                    raise ValueError('rotation did not fall back to the full screen')
            for name in [f'{i}.png' for i in range(6)] + ['closed.png']:
                with Image.open(shots['baseline'] / name) as first, Image.open(shots['optimized'] / name) as second:
                    before, after = first.convert('RGB'), second.convert('RGB')
                    if before.size != (width, height) or after.size != before.size or ImageChops.difference(before, after).getbbox():
                        raise ValueError(f'visible screen changed: {width} {name}')
            for index, region in enumerate(results['optimized']['regions'], 1):
                with Image.open(shots['optimized'] / f'{index-1}.png') as previous, \
                     Image.open(shots['optimized'] / f'{index}.png') as current:
                    changed = ImageChops.difference(previous.convert('RGB'), current.convert('RGB')).getbbox()
                if not changed or not (region['x'] <= changed[0] and region['y'] <= changed[1]
                        and region['x'] + region['w'] >= changed[2] and region['y'] + region['h'] >= changed[3]):
                    raise ValueError(f'changed pixels outside refresh region: {width} step {index}')
            result[str(width)] = results
        print(json.dumps({'cases': result, 'all_screenshots_identical': True, 'changed_pixels_inside_region': True}))


if __name__ == '__main__':
    main()
