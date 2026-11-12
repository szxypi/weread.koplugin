#!/usr/bin/env python3
"""Actual native document close against a local TXT fixture; no real account."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
import threading
from native_reader_fixture import NativeReaderServer
from run_native_reader_position import FRAME,FLAGS,COUNTS,decode as decode_reopen
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate,run_child

CASES=('plain','noack','cancel','reopen','account')
CLOSE_FLAGS={'document_closed','archive_worker','workers_reaped','no_closed_document_calls','confirmed','unknown_retained','cancelled'}


def decode(raw,kind):
    if kind not in CASES or not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('native_close/frame')
    r=json.loads(raw.split(FRAME)[1]);expected=FLAGS|set(COUNTS)|{'result','phase','close_case'}
    if not isinstance(r,dict) or set(r)!=expected:raise ValueError('native_close/schema')
    a=r['close_case']
    if (not isinstance(a,dict) or set(a)!=CLOSE_FLAGS|{'kind','close_posts','failed_line'} or a['kind']!=kind
            or any(type(a[k]) is not bool for k in CLOSE_FLAGS)
            or type(a['close_posts']) is not int or not 0<=a['close_posts']<=1
            or type(a['failed_line']) is not int or not 0<=a['failed_line']<=10000
            or r['result'] not in ('PASS','UNVERIFIED') or r['phase'] not in ('init','manual','timer','cancel','unknown','complete')
            or any(type(r[k]) is not bool for k in FLAGS)
            or any(type(r[k]) is not int or not 0<=r[k]<=cap for k,cap in COUNTS.items())):raise ValueError('native_close/schema')
    if r['result']=='PASS':
        if (r['phase']!='complete' or r['failed_line'] or a['failed_line'] or r['web_posts']
                or not all(r[k] for k in ('manual','original_local_units','summary_not_in_checkpoints','reader_from_shelf','source_workers','workers_reaped','parent_only_document'))
                or any(r[k] for k in ('timed','unknown_not_replayed','pending_reopened','timer_cancelled'))
                or not all(a[k] for k in ('document_closed','archive_worker','workers_reaped','no_closed_document_calls'))
                or a['confirmed']!=(kind=='plain') or a['unknown_retained']!=(kind=='noack')
                or a['cancelled']!=(kind in ('cancel','reopen','account'))
                or a['close_posts']!=int(kind in ('plain','noack')) or r['native_posts']!=1+a['close_posts']):raise ValueError('native_close/incomplete')
    return r


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--koreader',required=True,type=Path);p.add_argument('--candidate',required=True,type=Path)
    p.add_argument('--case',choices=CASES,default='plain');p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167)
    a=p.parse_args(argv);runtime=a.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not all(1<=n<=4096 for n in (a.width,a.height,a.dpi)):p.error('bounded Linux runtime required')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):p.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report=dict(result='UNVERIFIED',case=a.case,synthetic_only=True,account_data_posts=0,profile_removed=False,stages=[],
                server_posts=0,counts_preserved=False,offline_requests=0,installed=None,error='none')
    root=server=None
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-reader-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(a.candidate,profile/'plugins')
            server=NativeReaderServer();threading.Thread(target=server.serve_forever,daemon=True).start()
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                     EMULATE_READER_W=str(a.width),EMULATE_READER_H=str(a.height),EMULATE_READER_DPI=str(a.dpi),
                     WEREAD_NATIVE_READER_PORT=str(server.server_port),WEREAD_NATIVE_CLOSE_CASE=a.case)
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/native_reader_position_probe.lua'
            code,out,repaint=run_child([str(runtime/'luajit'),str(probe),'close'],env,b'',runtime,timeout=180)
            stage=decode(out,a.case);report['stages'].append(stage)
            if code or repaint or stage['result']!='PASS':raise ValueError('native_close/runtime')
            if a.case=='noack':
                before=server.request_totals.copy()
                code,out,repaint=run_child([str(runtime/'luajit'),str(probe),'reopen'],env,b'',runtime,timeout=180)
                stage=decode_reopen(out,'reopen');report['stages'].append(stage)
                report['offline_requests']=sum((server.request_totals-before).values())
                if code or repaint or stage['result']!='PASS' or report['offline_requests']:raise ValueError('native_close/reopen')
            report['installed']=check_installed(a.candidate,profile)
            if server.native_posts!=1+int(a.case in ('plain','noack')) or not server.preserved_counts():raise ValueError('native_close/server')
            report['result']='PASS'
    except subprocess.TimeoutExpired:report['error']='timeout'
    except Exception as error:
        import re
        report['error']=str(error) if re.fullmatch('native_close/[a-z_]+',str(error)) else 'runner'
    finally:
        if server:
            report['server_posts']=server.native_posts;report['counts_preserved']=server.preserved_counts();server.shutdown();server.server_close()
        report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report,indent=2));return int(report['result']!='PASS' or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
