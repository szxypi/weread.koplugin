#!/usr/bin/env python3
"""Benchmark a synthetic long shelf in packaged KOReader, without account data."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_LONG_LIST_BENCHMARK='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--width', type=int, default=1264)
    parser.add_argument('--height', type=int, default=1680)
    parser.add_argument('--dpi', type=int, default=300)
    parser.add_argument('--screenshots', type=Path, help='Save synthetic screenshots for pixel comparison')
    parser.add_argument('--rtl', action='store_true', help='Test a mirrored interface')
    parser.add_argument('--no-xtext', action='store_true', help='Test KOReader without text shaping')
    parser.add_argument('--max-row-paints', type=int, help='Fail if the measured repaint count exceeds this limit')
    parser.add_argument('--max-row-layout-updates', type=int, help='Limit the number of rows positioned across repaints')
    parser.add_argument('--max-event-visits', type=int, help='Fail if point gestures visit too many shelf rows')
    parser.add_argument('--max-materialized-rows', type=int, help='Fail if too many shelf row controls are retained')
    parser.add_argument('--max-visible-visits', type=int, help='Fail if visible-book lookups examine too many shelf rows')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-long-list-', dir='/dev/shm') as directory:
        root = Path(directory)
        profile, xdg = root / 'profile', root / 'xdg'
        (profile / 'plugins').mkdir(parents=True)
        xdg.mkdir(mode=0o700)
        candidate = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        extract_candidate(candidate, profile / 'plugins')
        env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), EMULATE_READER='1',
                   EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(args.width),
                   EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi))
        if args.screenshots:
            args.screenshots.mkdir(parents=True, exist_ok=True)
            env['WEREAD_LONG_LIST_SHOTS'] = str(args.screenshots.resolve())
        if args.rtl:
            env['WEREAD_LONG_LIST_RTL'] = '1'
        if args.no_xtext:
            env['WEREAD_LONG_LIST_NO_XTEXT'] = '1'
        code, output, repaint = run_child([str(runtime / 'luajit'), str(repo / 'spec/koreader/eink_long_list_benchmark.lua')],
                                          env, b'', runtime, timeout=150)
        if output.count(FRAME) != 1:
            raise ValueError('benchmark result missing')
        result = json.loads(output.split(FRAME)[1])
        print(json.dumps(result))
        if code or repaint or result['result'] != 'PASS':
            raise ValueError('benchmark failed')
        if args.max_row_paints is not None and result['row_paints'] > args.max_row_paints:
            raise ValueError('too many offscreen rows painted')
        if args.max_row_layout_updates is not None and result['row_layout_updates'] > args.max_row_layout_updates:
            raise ValueError('too many rows positioned during scrolling')
        if args.max_event_visits is not None and result['event_row_visits'] > args.max_event_visits:
            raise ValueError('too many rows received point gestures')
        if args.max_materialized_rows is not None and result['max_materialized_rows'] > args.max_materialized_rows:
            raise ValueError('too many row controls remained active')
        if args.max_visible_visits is not None and result['lookup_row_visits'] > args.max_visible_visits:
            raise ValueError('visible-book lookups examined too many rows')


if __name__ == '__main__':
    main()
