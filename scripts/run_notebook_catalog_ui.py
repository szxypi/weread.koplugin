#!/usr/bin/env python3
"""Native notebook catalog acceptance with a disposable tmpfs KOReader profile."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
import zipfile
from run_persistent_ui_probe import extract_candidate,run_child

FRAME=b'\nWEREAD_NOTEBOOK_RESULT='
FLAGS={'anonymous_credentials','transport_guard','worker_heartbeat','native_filemanager','menu_navigation','search_sort','saved_note_search','file_sqlite',
       'account_isolation','cache_session_free','workers_reaped','credential_audit'}


def validate_stage(value,mode,count):
    keys=FLAGS|{'result','mode','phase','pages','books','requests','forbidden','failed_line'}
    if not isinstance(value,dict) or set(value)!=keys:raise ValueError('ui_schema')
    if any(type(value[key]) is not bool or not value[key] for key in FLAGS):raise ValueError('ui_flags')
    if any(type(value[key]) is not int or value[key]<0 for key in ('pages','books','requests','forbidden','failed_line')):
        raise ValueError('ui_numbers')
    if (value['result']!='PASS' or value['mode']!=mode or value['phase']!='complete' or value['books']!=count
            or value['pages']<1 or value['requests']!=int(mode=='live') or value['forbidden'] or value['failed_line']):
        raise ValueError('ui_incomplete')


def main(argv=None):
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True);parser.add_argument('--synthetic',action='store_true')
    parser.add_argument('--cached-notes-sample',action='store_true')
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or min(args.width,args.height,args.dpi)<1:parser.error('Linux and built runtime required')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    output={'ui':{'result':'UNVERIFIED','profile_removed':False,'stages':[]}};root=None
    try:
        raw=sys.stdin.buffer.read(8*1024*1024+1)
        if len(raw)>8*1024*1024:raise ValueError('input_limit')
        payload=json.loads(raw)
        if (payload.get('synthetic') is True)!=args.synthetic:raise ValueError('input_scope')
        if args.cached_notes_sample != ('saved_samples' in payload) or args.synthetic and args.cached_notes_sample:
            raise ValueError('input_scope')
        if args.cached_notes_sample and (not isinstance(payload['saved_samples'],list) or len(payload['saved_samples'])!=2
                or [row.get('kind') for row in payload['saved_samples'] if isinstance(row,dict)]!=['marks','thoughts']):
            raise ValueError('input_scope')
        count=len(payload['source']['books'])
        if not 1<=count<=5000:raise ValueError('input_count')
        with tempfile.TemporaryDirectory(prefix='weread-notebook-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',
                EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            if args.synthetic:env['WEREAD_NOTEBOOK_SYNTHETIC']='1'
            if args.cached_notes_sample:env['WEREAD_NOTEBOOK_SAVED_SAMPLES']='1'
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/notebook_catalog_probe.lua';stages=[];live=None
            for mode in ('live','reopen'):
                code,rawout,repaint=run_child([str(runtime/'luajit'),str(probe),mode],env,raw,runtime,timeout=180)
                if len(rawout)>12*1024*1024 or rawout.count(FRAME)!=1:raise ValueError('ui_frame')
                result=json.loads(rawout.split(FRAME)[1]);stages.append(result.get('ui'));output['ui']['stages']=stages
                if code or repaint:raise ValueError('ui_child')
                validate_stage(result['ui'],mode,count)
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
