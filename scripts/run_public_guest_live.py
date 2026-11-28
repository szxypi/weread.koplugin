#!/usr/bin/env python3
"""Read-only native guest search against public book data in a disposable profile."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME=b'\nWEREAD_PUBLIC_GUEST='
TRANSFER=b'\nWEREAD_PUBLIC_TRANSFER='


def valid_stage(stage,code,repaint,mode='live'):
    expected={'result','phase','mode','requests','first','second','guest','native_host','detail','public_intro','manual_refresh','metadata_requests','forbidden'}
    return (isinstance(stage,dict) and set(stage)==expected and code==0 and repaint is False
            and mode in ('live','reopen') and stage['mode']==mode and stage['result']=='PASS' and stage['phase']=='complete'
            and type(stage['requests']) is int and stage['requests']==(3 if mode=='live' else 0)
            and type(stage['metadata_requests']) is int and stage['metadata_requests']==(2 if mode=='live' else 0)
            and type(stage['forbidden']) is int and stage['forbidden']==0
            and all(type(stage[k]) is int and (1<=stage[k]<=100 if mode=='live' else stage[k]==0) for k in ('first','second'))
            and all(stage[k] is True for k in ('guest','native_host','detail','public_intro'))
            and stage['manual_refresh'] is (mode=='live'))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args();runtime=args.koreader.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file()
            or min(args.width,args.height,args.dpi)<1
            or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
        parser.error('requires Linux, tmpfs and a built KOReader runtime')
    result={'result':'UNVERIFIED','profile_removed':False,'stages':[]}
    root=None
    try:
        with tempfile.TemporaryDirectory(prefix='weread-public-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True)
            (profile/'books').mkdir();(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',
                EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),
                EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/public_guest_live.lua'
            payload=b''
            for mode in ('live','reopen'):
                code,out,repaint=run_child([str(runtime/'luajit'),str(probe),mode],env,payload,runtime,timeout=100)
                if len(out)>1024*1024 or out.count(FRAME)!=1:raise ValueError('invalid report')
                stage=json.loads(out.split(FRAME)[1]);result['stages'].append(stage)
                if not valid_stage(stage,code,repaint,mode):raise ValueError('stage failed')
                if mode=='live':
                    if out.count(TRANSFER)!=1:raise ValueError('invalid transfer')
                    transfer=json.loads(out.split(TRANSFER)[1].split(FRAME)[0])
                    if set(transfer)!={'book_id','intro_hash'}:raise ValueError('invalid transfer')
                    payload=json.dumps(transfer).encode()
            result['result']='PASS'
    except (OSError,ValueError,subprocess.TimeoutExpired):
        result['result']='UNVERIFIED'
    finally:
        result['profile_removed']=root is not None and not root.exists()
    print(json.dumps(result))
    return 0 if result['result']=='PASS' and result['profile_removed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
