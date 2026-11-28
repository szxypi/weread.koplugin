#!/usr/bin/env python3
"""Offline native UI export of supplied private snapshots in disposable tmpfs."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

from my_cloud_marks_model import project
from run_my_cloud_marks_ui import FRAME as UI_FRAME, validate_stage
from run_persistent_ui_probe import extract_candidate, run_child
from verify_cloud_notes_export import FRAME, compare

UI_REPORT = b'\nWEREAD_CLOUD_NOTES_UI='


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    args = parser.parse_args(argv)
    runtime = args.koreader.resolve()
    if (sys.platform != 'linux' or not (runtime/'luajit').is_file()
            or min(args.width, args.height, args.dpi) < 1
            or not any(line.split()[1:3] == ['/dev/shm', 'tmpfs']
                       for line in Path('/proc/mounts').read_text().splitlines())):
        parser.error('Linux, KOReader and /dev/shm tmpfs are required')
    report = dict(result='UNVERIFIED', profile_removed=False, stages=[])
    result = None
    root = None
    try:
        raw = sys.stdin.buffer.read(8*1024*1024+1)
        if len(raw) > 8*1024*1024:
            raise ValueError('input_limit')
        payload = json.loads(raw)
        if payload.get('owner_export') is not True or payload.get('synthetic') is True or payload.get('variant') is not None:
            raise ValueError('input_scope')
        marks = project(payload['source'], payload['book_id'], payload['owner'], payload['now'])
        thoughts = payload['other_thoughts']
        repo = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(prefix='weread-marks-', dir='/dev/shm') as temporary:
            root = Path(temporary)
            profile, xdg = root/'profile', root/'xdg'
            (profile/'plugins').mkdir(parents=True)
            xdg.mkdir(mode=0o700)
            extract_candidate(args.candidate, profile/'plugins')
            env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), SDL_VIDEODRIVER='dummy',
                       LD_LIBRARY_PATH=str(runtime/'libs'), EMULATE_READER='1', EMULATE_BW_SCREEN='1',
                       EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(args.width), EMULATE_READER_H=str(args.height),
                       EMULATE_READER_DPI=str(args.dpi), WEREAD_OWNER_EXPORT='1',
                       WEREAD_OWNER_EXPORT_GUARD=str(repo/'spec/koreader/offline_network_guard.lua'))
            for seed in ('1', '0'):
                env['WEREAD_OWNER_EXPORT_SEED'] = seed
                code, output, repaint = run_child([str(runtime/'luajit'), str(repo/'spec/koreader/my_cloud_marks_probe.lua'),
                                                   'reopen'], env, raw, runtime, timeout=180)
                if len(output)>24*1024*1024 or output.count(UI_FRAME)!=1:
                    raise ValueError('ui_frame')
                value=json.loads(output.split(UI_FRAME,1)[1]);stage=value.get('ui')
                if isinstance(stage,dict):
                    report['stages'].append({key:stage[key] for key in ('result','phase','failed_line','requests','forbidden') if key in stage})
                if code or repaint or not isinstance(stage,dict) or stage.get('export_ui_checked') is not True:
                    raise ValueError('ui_child')
                plain=dict(stage);plain.pop('export_ui_checked')
                validate_stage(plain,'reopen',len(marks['updated']))
                if value.get('model')!=marks or value.get('native')!=marks or value.get('requests')!=0:
                    raise ValueError('ui_snapshot')
                result=value.get('owner_export')
                compare(FRAME+json.dumps(result,ensure_ascii=False).encode(),marks,thoughts)
            report.update(result='PASS',offline_network_guard=True,independent_reopen=True,temporary_files_removed=True)
    except (Exception, KeyboardInterrupt):
        pass
    finally:
        report['profile_removed']=root is not None and not root.exists()
    sys.stdout.buffer.write(UI_REPORT+json.dumps(report).encode()+b'\n')
    if result is not None and report['result']=='PASS' and report['profile_removed']:
        sys.stdout.buffer.write(FRAME+json.dumps(result,ensure_ascii=False).encode()+b'\n')
        return 0
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
