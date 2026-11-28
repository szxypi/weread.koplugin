#!/usr/bin/env python3
"""Private tmpfs native review cache verification using a saved read-only sample."""
import argparse
import json
import os
from pathlib import Path
import resource
import sys
import tempfile
from run_persistent_ui_probe import extract_candidate,run_child
from run_owner_reading_probe import check_installed


def main():
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167)
    kind=parser.add_mutually_exclusive_group();kind.add_argument('--replies',action='store_true');kind.add_argument('--thought',action='store_true')
    args=parser.parse_args()
    runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or min(args.width,args.height,args.dpi)<1:
        parser.error('Linux and built runtime required')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):
        parser.error('tmpfs required')
    result=dict(result='UNVERIFIED',phase='runner',requests=0,painted=False,heartbeat=False)
    try:
        raw=sys.stdin.buffer.read(8*1024*1024+1)
        if len(raw)>8*1024*1024:raise ValueError('input_limit')
        payload=json.loads(raw);grant=payload['credentials'];payload['vid']=grant['vid']
        with tempfile.TemporaryDirectory(prefix='weread-review-cache-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True)
            xdg=root/'xdg';xdg.mkdir(mode=0o700);extract_candidate(args.candidate,profile/'plugins')
            check_installed(args.candidate,profile)
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),EMULATE_READER='1',EMULATE_BW_SCREEN='1',
                EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),
                EMULATE_READER_DPI=str(args.dpi))
            name='thought_replies_live_probe.lua' if args.thought else 'native_review_replies_live_probe.lua' if args.replies else 'native_book_reviews_cache_owner_probe.lua'
            probe=Path(__file__).resolve().parent.parent/'spec/koreader'/name
            marker=b'\nWEREAD_THOUGHT_REPLIES_UI=' if args.thought else b'\nWEREAD_NATIVE_REPLIES_UI=' if args.replies else b'\nWEREAD_REVIEW_CACHE_OWNER='
            total=1 if args.thought else 5 if args.replies else 2
            for mode in ('online','offline'):
                if mode=='offline':payload.pop('credentials',None)
                source=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
                mode_env={'WEREAD_THOUGHT_REPLY_CACHE_MODE':mode} if args.thought else {'WEREAD_REPLY_CACHE_MODE':mode} if args.replies else {'WEREAD_REVIEW_CACHE_MODE':mode}
                code,out,repaint=run_child([str(runtime/'luajit'),str(probe)],dict(env,**mode_env),
                                           source,runtime,timeout=100)
                if code or repaint or out.count(marker)!=1:raise ValueError('native_stage')
                stage=json.loads(out.split(marker,1)[1].splitlines()[0])
                if stage!=dict(result='PASS',phase='complete',requests=total if mode=='online' else 0,painted=True,heartbeat=True):
                    raise ValueError('native_stage')
        if root.exists():raise ValueError('profile_not_removed')
        result=dict(result='PASS',phase='complete',requests=total,painted=True,heartbeat=True)
    except Exception:
        result=dict(result='UNVERIFIED',phase='runner',requests=0,painted=False,heartbeat=False)
    marker=b'\nWEREAD_THOUGHT_REPLIES_UI=' if args.thought else b'\nWEREAD_NATIVE_REPLIES_UI=' if args.replies else b'\nWEREAD_NATIVE_REVIEWS_UI='
    sys.stdout.buffer.write(marker+json.dumps(result).encode()+b'\n')
    return 0 if result['result']=='PASS' else 1


if __name__=='__main__':raise SystemExit(main())
