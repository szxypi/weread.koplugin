#!/usr/bin/env python3
"""Native own-mark live/reopen UI in a disposable Linux tmpfs profile."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile
from run_persistent_ui_probe import extract_candidate,run_child

FRAME=b'\nWEREAD_MY_MARKS_RESULT='
FLAGS={'anonymous_credentials','transport_guard','worker_heartbeat','native_filemanager','file_sqlite',
       'account_isolation','cache_session_free','all_quotes','workers_reaped','credential_audit'}


def native_budget(total):
    if type(total) is not int or not 0<=total<=5000:raise ValueError('ui_count')
    count,requests=20,1
    while count<total:count=min(5000,count*2);requests+=1
    return requests


def validate_stage(value,mode,count,*,synthetic=False,shots=False,thoughts=False):
    keys=FLAGS|{'result','mode','phase','screenshots','pages','quotes','requests','forbidden','failed_line','fault_cases'}
    if not isinstance(value,dict) or set(value)!=keys:raise ValueError('ui_schema')
    if any(type(value[key]) is not bool or not value[key] for key in FLAGS):raise ValueError('ui_flags')
    if any(type(value[key]) is not int or value[key]<0 for key in ['screenshots','pages','quotes','requests','forbidden','failed_line','fault_cases']):raise ValueError('ui_numbers')
    if (value['result']!='PASS' or value['mode']!=mode or value['phase']!='complete' or value['screenshots']!=(3 if shots else 0) or value['forbidden']
            or value['failed_line'] or value['requests']!=((10 if thoughts else 6) if synthetic and mode=='live' else (native_budget(count) if thoughts and mode=='live' else int(mode=='live')))
            or value['fault_cases']!=(6 if synthetic and mode=='live' else 0) or not 1<=value['pages']<=1000 or value['quotes']!=count):raise ValueError('ui_incomplete')
    return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--variant',choices=['thoughts']);parser.add_argument('--synthetic',action='store_true');parser.add_argument('--screenshots',type=Path);parser.add_argument('--candidate',type=Path,required=True);parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167);args=parser.parse_args(argv)
    if args.screenshots and not args.synthetic:parser.error('screenshots require synthetic fixtures')
    runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or min(args.width,args.height,args.dpi)<1:parser.error('Linux and built runtime required')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    output={'ui':{'result':'UNVERIFIED','profile_removed':False,'stages':[]}};root=None
    try:
        raw=sys.stdin.buffer.read(8*1024*1024+1)
        if len(raw)>8*1024*1024:raise ValueError('input_limit')
        payload=json.loads(raw);count=len(payload['source']['reviews' if args.variant=='thoughts' else 'updated'])
        if payload.get('variant')!=args.variant:raise ValueError('input_scope')
        if (payload.get('synthetic') is True)!=args.synthetic:raise ValueError('input_scope')
        if args.screenshots:args.screenshots.mkdir(parents=True,exist_ok=False)
        with tempfile.TemporaryDirectory(prefix='weread-marks-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',
                EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            if args.variant=='thoughts':env['WEREAD_PERSONAL_THOUGHTS']='1'
            if args.synthetic:env['WEREAD_MARKS_SYNTHETIC']='1'
            if args.screenshots:env['WEREAD_MARKS_SHOTS']=str(args.screenshots.resolve())
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/my_cloud_marks_probe.lua'
            stages=[];live=None
            for mode in ('live','reopen'):
                code,rawout,repaint=run_child([str(runtime/'luajit'),str(probe),mode],env,raw,runtime,timeout=180)
                if len(rawout)>12*1024*1024 or rawout.count(FRAME)!=1:raise ValueError('ui_frame')
                result=json.loads(rawout.split(FRAME)[1]);stages.append(result.get('ui'))
                output['ui']['stages']=stages
                if code or repaint:raise ValueError('ui_child')
                validate_stage(result['ui'],mode,count,synthetic=args.synthetic,shots=bool(args.screenshots),thoughts=args.variant=='thoughts')
                if live is None:live=result
                elif result['native']!=live['native'] or result['model']!=live['model']:raise ValueError('ui_reopen')
            files=0
            with zipfile.ZipFile(args.candidate) as archive:
                for item in archive.infolist():
                    if item.is_dir():continue
                    path=profile/'plugins'/item.filename
                    if path.is_symlink() or not path.is_file() or archive.read(item)!=path.read_bytes():raise ValueError('candidate_layout')
                    files+=1
            output=dict(model=live['model'],native=live['native'],requests=live['requests'],ui=dict(result='PASS',profile_removed=False,
                installed_bytes_match=True,installed_files=files,stages=stages))
    except (Exception,subprocess.TimeoutExpired):pass
    finally:output['ui']['profile_removed']=root is not None and not root.exists()
    sys.stdout.buffer.write(FRAME+json.dumps(output,ensure_ascii=False).encode()+b'\n')
    return 0 if output['ui']['result']=='PASS' and output['ui']['profile_removed'] else 1


if __name__=='__main__':raise SystemExit(main())
