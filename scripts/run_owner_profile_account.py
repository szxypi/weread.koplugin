#!/usr/bin/env python3
"""Run native nickname refresh and fresh offline reopen in disposable tmpfs."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child
from run_owner_reading_probe import check_installed

FRAME=b'\nWEREAD_PROFILE_ACCOUNT_UI='
FLAGS={'name_matches','sqlite_verified','offline_cache','worker_reaped','account_isolated','credentials_not_on_disk'}


def decode_stage(raw,mode):
    if not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('frame')
    value=json.loads(raw.split(FRAME)[1])
    if (not isinstance(value,dict) or set(value)!=FLAGS|{'result','mode','phase','requests','forbidden','failed_line'}
            or value['result'] not in ('PASS','UNVERIFIED') or value['mode']!=mode
            or value['phase'] not in ('init','profile','audit','complete')
            or any(type(value[key]) is not bool for key in FLAGS)
            or any(type(value[key]) is not int or not 0<=value[key]<=1000 for key in ('requests','forbidden','failed_line'))):
        raise ValueError('schema')
    if value['result']=='PASS' and (value['phase']!='complete' or not all(value[key] for key in FLAGS-{'offline_cache'})
            or value['offline_cache']!=(mode=='reopen') or value['requests']!=(1 if mode=='live' else 0)
            or value['forbidden'] or value['failed_line']):raise ValueError('incomplete')
    return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167);parser.add_argument('--mock-port',type=int)
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or min(args.width,args.height,args.dpi)<1:parser.error('requires Linux and KOReader')
    if args.mock_port is not None and not 1<=args.mock_port<=65535:parser.error('invalid mock port')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):parser.error('/dev/shm must be tmpfs')
    report=dict(result='UNVERIFIED',tmpfs_profile=True,profile_removed=False,stages=[],installed_bytes_match=False)
    root=None
    try:
        raw=sys.stdin.buffer.read(65537)
        if len(raw)>65536:raise ValueError('input')
        payload=json.loads(raw)
        if payload.get('mock_port')!=args.mock_port:raise ValueError('input')
        if args.mock_port is not None and (payload.get('owner')!='900000' or payload.get('cookies',{}).get('wr_skey')!='mock-only'):
            raise ValueError('input')
        with tempfile.TemporaryDirectory(prefix='weread-profile-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(profile/'books').mkdir()
            (root/'xdg').mkdir(mode=0o700);extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',
                     EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            if args.mock_port is not None:env['WEREAD_PROFILE_MOCK']=str(args.mock_port)
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_profile_account_ui.lua'
            for mode in ('live','reopen'):
                code,out,repaint=run_child([str(runtime/'luajit'),str(probe),mode],env,raw,runtime,timeout=100)
                stage=decode_stage(out,mode);report['stages'].append(stage)
                if code or repaint or stage['result']!='PASS':raise ValueError('stage')
            check_installed(args.candidate,profile);report.update(installed_bytes_match=True,result='PASS')
    except Exception:
        pass
    finally:
        report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report))
    return 0 if report['result']=='PASS' and report['profile_removed'] else 1


if __name__=='__main__':raise SystemExit(main())
