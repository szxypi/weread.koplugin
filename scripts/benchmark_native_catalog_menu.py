#!/usr/bin/env python3
"""Compare large native chapter menus with synthetic KOReader data."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

from PIL import Image, ImageChops
from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_NATIVE_CATALOG_MENU='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='34e0c16eae641ac57b26263e877fbf0eac11964a')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    result = {}
    with tempfile.TemporaryDirectory(prefix='weread-catalog-menu-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        archive = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(archive)],
                       check=True, capture_output=True)
        for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
            for kind, count in (('online', 1500), ('online', 20000), ('offline', 2000)):
                cases, images = {}, {}
                for mode in ('baseline', 'optimized'):
                    profile = root / f'{width}-{kind}-{count}-{mode}'
                    (profile / 'plugins').mkdir(parents=True)
                    extract_candidate(archive, profile / 'plugins')
                    plugin = profile / 'plugins/weread.koplugin'
                    if mode == 'baseline':
                        for relative in ('weread/ui/common.lua', 'weread/ui/native_direct_reading.lua'):
                            (plugin / relative).write_bytes(subprocess.run(['git', 'show', args.baseline_ref + ':' + relative],
                                cwd=repo, check=True, capture_output=True).stdout)
                    xdg = root / f'xdg-{width}-{kind}-{count}-{mode}'
                    xdg.mkdir(mode=0o700)
                    shots = root / f'shots-{width}-{kind}-{count}-{mode}'
                    shots.mkdir()
                    env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), SDL_VIDEODRIVER='dummy',
                        EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                        EMULATE_READER_W=str(width), EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi),
                        WEREAD_CATALOG_SHOTS=str(shots))
                    samples = []
                    for _ in range(3):
                        code, output, repaint = run_child([str(runtime / 'luajit'),
                            str(repo / 'spec/koreader/native_catalog_menu_benchmark.lua'), str(count), kind],
                            env, b'', runtime, timeout=120)
                        if code or repaint or output.count(FRAME) != 1:
                            raise ValueError('native catalog menu benchmark failed')
                        row = json.loads(output.split(FRAME)[1])
                        if row['result'] != 'PASS' or not row['selection'] or not row['unavailable']:
                            raise ValueError('native catalog menu selection failed')
                        samples.append(row)
                    cases[mode] = {'samples': samples,
                        'median_seconds': statistics.median(row['seconds'] for row in samples),
                        'median_retained_lua_kib': statistics.median(row['retained_lua_kib'] for row in samples)}
                    images[mode] = shots
                for image in ('first.png', 'last.png'):
                    with Image.open(images['baseline'] / image) as a, Image.open(images['optimized'] / image) as b:
                        if a.size != (width, height) or ImageChops.difference(a.convert('RGB'), b.convert('RGB')).getbbox():
                            raise ValueError('native catalog screen changed')
                result[f'{width}x{height}-{kind}-{count}'] = cases
    print(json.dumps({'cases': result, 'first_and_last_screens_identical': True}))


if __name__ == '__main__':
    main()
