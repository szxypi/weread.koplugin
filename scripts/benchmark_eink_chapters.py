#!/usr/bin/env python3
"""Measure a synthetic chapter catalog in packaged KOReader without network access."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_CHAPTER_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, help='Use an existing release package for comparison.')
    parser.add_argument('--width', type=int, default=1264)
    parser.add_argument('--height', type=int, default=1680)
    parser.add_argument('--dpi', type=int, default=300)
    parser.add_argument('--chapters', type=int, default=1500, help='Number of chapters in the synthetic catalog.')
    parser.add_argument('--screenshots', type=Path)
    parser.add_argument('--rtl', action='store_true')
    parser.add_argument('--no-xtext', action='store_true')
    parser.add_argument('--check-prepaint-press', action='store_true',
                        help='Confirm a physical key selects the new focus before the queued scroll repaint.')
    parser.add_argument('--check-cache-update', action='store_true',
                        help='Measure a downloaded chapter status update against rebuilding the catalog.')
    parser.add_argument('--max-row-paints', type=int)
    parser.add_argument('--max-row-layout-updates', type=int)
    parser.add_argument('--max-materialized-rows', type=int)
    parser.add_argument('--max-event-visits', type=int)
    parser.add_argument('--max-initial-text-widgets', type=int)
    args = parser.parse_args()
    if args.chapters < 100:
        parser.error('--chapters must be at least 100 for the scrolling benchmark')
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-chapters-', dir='/dev/shm') as directory:
        root = Path(directory)
        profile, xdg = root / 'profile', root / 'xdg'
        (profile / 'plugins').mkdir(parents=True)
        xdg.mkdir(mode=0o700)
        candidate = args.candidate
        if candidate is None:
            candidate = root / 'candidate.zip'
            subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)],
                           check=True, capture_output=True)
        extract_candidate(candidate, profile / 'plugins')
        env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), EMULATE_READER='1',
                   EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(args.width),
                   EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi),
                   WEREAD_CHAPTER_COUNT=str(args.chapters))
        if args.screenshots:
            args.screenshots.mkdir(parents=True, exist_ok=True)
            env['WEREAD_CHAPTER_SHOTS'] = str(args.screenshots.resolve())
        if args.rtl:
            env['WEREAD_CHAPTER_RTL'] = '1'
        if args.no_xtext:
            env['WEREAD_CHAPTER_NO_XTEXT'] = '1'
        if args.check_prepaint_press:
            env['WEREAD_CHAPTER_PREPAINT_PRESS'] = '1'
        if args.check_cache_update:
            env['WEREAD_CHAPTER_CACHE_UPDATE'] = '1'
        code, output, repaint = run_child([str(runtime / 'luajit'), str(repo / 'spec/koreader/eink_chapter_benchmark.lua')],
                                          env, b'', runtime, timeout=150)
        if output.count(FRAME) != 1:
            raise ValueError('benchmark result missing')
        result = json.loads(output.split(FRAME)[1])
        geometry = result.pop('geometry', [])
        result['geometry_sha256'] = hashlib.sha256(json.dumps(geometry, separators=(',', ':')).encode()).hexdigest()
        print(json.dumps(result, ensure_ascii=False))
        if code or repaint or result['result'] != 'PASS':
            raise ValueError('benchmark failed')
        for limit, field in ((args.max_row_paints, 'row_paints'),
                             (args.max_row_layout_updates, 'row_layout_updates'),
                             (args.max_materialized_rows, 'max_materialized_rows'),
                             (args.max_event_visits, 'event_row_visits'),
                             (args.max_initial_text_widgets, 'initial_text_widgets')):
            if limit is not None and result[field] > limit:
                raise ValueError(f'{field} exceeds limit')


if __name__ == '__main__':
    main()
