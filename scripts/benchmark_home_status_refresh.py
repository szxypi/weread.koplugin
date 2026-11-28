#!/usr/bin/env python3
"""Compare synthetic home status redraws in packaged KOReader."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from PIL import Image, ImageChops
from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_HOME_STATUS_REFRESH='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='405c9fd27278e60b4d2437104bd701cc44bb4f61')
    parser.add_argument('--rtl', action='store_true', help='Test a mirrored interface')
    parser.add_argument('--debug-dir', type=Path, help='Save synthetic screenshots')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    cases = {}
    with tempfile.TemporaryDirectory(prefix='weread-home-status-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        archive = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(archive)],
                       check=True, capture_output=True)
        for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
            results, shots = {}, {}
            for mode in ('baseline', 'optimized'):
                profile = root / f'{width}-{mode}'
                (profile / 'plugins').mkdir(parents=True)
                extract_candidate(archive, profile / 'plugins')
                if mode == 'baseline':
                    (profile / 'plugins/weread.koplugin/weread/ui/library_view.lua').write_bytes(
                        subprocess.run(['git', 'show', args.baseline_ref + ':weread/ui/library_view.lua'],
                                       cwd=repo, check=True, capture_output=True).stdout)
                xdg = root / f'xdg-{width}-{mode}'
                xdg.mkdir(mode=0o700)
                shots[mode] = root / f'shots-{width}-{mode}'
                shots[mode].mkdir()
                env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), SDL_VIDEODRIVER='dummy',
                    EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                    EMULATE_READER_W=str(width), EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi),
                    WEREAD_HOME_SHOTS=str(shots[mode]))
                if args.rtl:
                    env['WEREAD_HOME_RTL'] = '1'
                code, output, repaint = run_child([str(runtime / 'luajit'),
                    str(repo / 'spec/koreader/home_status_refresh_benchmark.lua')], env, b'', runtime, timeout=120)
                if code or repaint or output.count(FRAME) != 1:
                    raise ValueError('home status refresh benchmark failed')
                row = json.loads(output.split(FRAME)[1])
                if row['result'] != 'PASS' or not row['overlay_fallback'] or not row['rotation_fallback'] or not row['reinit_fallback']:
                    raise ValueError('home status fallback failed')
                results[mode] = row
            expected = (10, 0) if args.rtl else (0, 10)
            if (results['optimized']['status_view_paints'], results['optimized']['status_direct_paints']) != expected:
                raise ValueError('home status used an unexpected repaint path')
            for name in ['initial', *(f'status{i}' for i in range(1, 11)), 'summary1', 'summary2', 'summary3', 'summary_reinit',
                         'overlay', 'covered', 'uncovered', 'rotation']:
                if args.debug_dir:
                    args.debug_dir.mkdir(parents=True, exist_ok=True)
                    for mode in ('baseline', 'optimized'):
                        shutil.copy2(shots[mode] / f'{name}.png', args.debug_dir / f'{width}-{mode}-{name}.png')
                with Image.open(shots['baseline'] / f'{name}.png') as a, Image.open(shots['optimized'] / f'{name}.png') as b:
                    difference = ImageChops.difference(a.convert('RGB'), b.convert('RGB')).getbbox()
                    if a.size != (width, height) or difference:
                        raise ValueError(f'home status screen changed: {name}, bounds={difference}')
            predecessors = {f'status{i}': ('initial' if i == 1 else f'status{i-1}') for i in range(1, 11)}
            predecessors.update(summary1='status10', summary2='summary1', summary3='summary2',
                                summary_reinit='summary3', covered='overlay', rotation='uncovered')
            # Mirrored layouts intentionally retain KOReader's existing full
            # widget paint and its original partial refresh requests.
            for name, prior in (() if args.rtl else predecessors.items()):
                region = results['optimized']['regions'][name]
                with Image.open(shots['optimized'] / f'{prior}.png') as a, Image.open(shots['optimized'] / f'{name}.png') as b:
                    changed = ImageChops.difference(a.convert('RGB'), b.convert('RGB')).getbbox()
                if changed and (changed[0] < region['x'] or changed[1] < region['y']
                                or changed[2] > region['x'] + region['w'] or changed[3] > region['y'] + region['h']):
                    raise ValueError('home update escaped requested refresh region: ' + name)
            cases[str(width)] = results
    print(json.dumps({'cases': cases, 'screen_pairs_pixel_identical': 38,
                      'changed_pixels_within_requested_regions': None if args.rtl else True,
                      'mirrored_full_repaint_preserved': args.rtl}))


if __name__ == '__main__':
    main()
