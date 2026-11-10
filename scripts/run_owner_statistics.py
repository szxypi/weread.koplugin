#!/usr/bin/env python3
"""Run live/offline native statistics in a disposable private tmpfs profile."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from owner_statistics_contract import FRAME,ERRORS,decode_stage
from run_persistent_ui_probe import extract_candidate,run_child


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--mock-port',type=int)
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or min(args.width,args.height,args.dpi)<1:parser.error('requires Linux and a built runtime')
    if args.mock_port is not None and not 1<=args.mock_port<=65535:parser.error('invalid mock port')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):parser.error('/dev/shm must be tmpfs')
    report=dict(result='UNVERIFIED',tmpfs_profile=True,profile_removed=False,stages=[],runner_error='none');root=None
    try:
        raw=sys.stdin.buffer.read(2*1024*1024+1)
        if len(raw)>2*1024*1024:raise ValueError('input_limit')
        payload=json.loads(raw)
        if payload.get('mock_port')!=args.mock_port:raise ValueError('input_limit')
        if args.mock_port is not None and payload.get('credentials')!=dict(vid='900000',accessToken='mock-native-access',
                refreshToken='mock-native-refresh',deviceId='eink334691225'+'1'*19):raise ValueError('input_limit')
        with tempfile.TemporaryDirectory(prefix='weread-statistics-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            (profile/'books').mkdir();extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',
                EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            if args.mock_port is not None:env['WEREAD_STATISTICS_MOCK']=str(args.mock_port)
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_statistics_probe.lua'
            for mode,tz in [('live','America/New_York'),('reopen','Pacific/Apia')]:
                code,out,repaint=run_child([str(runtime/'luajit'),str(probe),mode],dict(env,TZ=tz),raw,runtime,timeout=150)
                stage=decode_stage(out,mode);report['stages'].append(stage)
                if code or repaint or stage['result']!='PASS':raise ValueError('stage_unverified')
            report['result']='PASS'
    except subprocess.TimeoutExpired:report['runner_error']='child_timeout'
    except Exception as exc:report['runner_error']=str(exc) if str(exc) in ERRORS else 'runner_exception'
    finally:report['profile_removed']=root is not None and not root.exists()
    sys.stdout.buffer.write(FRAME+json.dumps(report).encode()+b'\n')
    return 0 if report['result']=='PASS' and report['profile_removed'] else 1


if __name__=='__main__':raise SystemExit(main())
