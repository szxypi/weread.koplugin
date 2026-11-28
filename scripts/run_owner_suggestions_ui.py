#!/usr/bin/env python3
"""Run the packaged real-account suggestion UI in an isolated tmpfs."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_OWNER_SUGGESTIONS_UI='


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or min(args.width,args.height,args.dpi)<1:
        parser.error('requires Linux and a built runtime')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):
        parser.error('/dev/shm must be tmpfs')
    report=dict(result='UNVERIFIED',tmpfs_profile=True,profile_removed=False,stage=None,reason='none');root=None
    try:
        raw=sys.stdin.buffer.read(1024*1024+1)
        if len(raw)>1024*1024 or not isinstance(json.loads(raw),dict):raise ValueError('input')
        with tempfile.TemporaryDirectory(prefix='weread-suggest-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True)
            (profile/'books').mkdir();(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',
                     EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),
                     EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_suggestions_ui.lua'
            code,out,repaint=run_child([str(runtime/'luajit'),str(probe)],env,raw,runtime,timeout=120)
            if len(out)>1024*1024 or out.count(FRAME)!=1:raise ValueError('stage')
            stage=json.loads(out.split(FRAME,1)[1].splitlines()[0]);report['stage']=stage
            if code or repaint or stage.get('result')!='PASS':raise ValueError('stage')
            report['result']='PASS'
    except subprocess.TimeoutExpired:report['reason']='timeout'
    except Exception as error:report['reason']=str(error) if str(error) in ('input','stage') else 'runner'
    finally:report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['result']=='PASS' and report['profile_removed'] else 1


if __name__=='__main__':raise SystemExit(main())
