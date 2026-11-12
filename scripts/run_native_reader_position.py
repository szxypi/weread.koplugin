#!/usr/bin/env python3
"""Packaged native TXT manual/timer acceptance with a loopback-only fixture."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import sys
import tempfile
import threading
from native_reader_fixture import NativeReaderServer
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate,run_child

FRAME=b'\nWEREAD_NATIVE_READER_RESULT='
FLAGS={'manual','timed','unknown_not_replayed','pending_reopened','original_local_units','summary_not_in_checkpoints',
       'parent_only_document','workers_reaped','reader_from_shelf','timer_cancelled','source_workers'}
COUNTS={'native_posts':3,'web_posts':0,'failed_line':10000}


def decode(raw,mode):
    if mode not in ('live','reopen') or not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('native_reader/frame')
    r=json.loads(raw.split(FRAME)[1])
    if (not isinstance(r,dict) or set(r)!=FLAGS|set(COUNTS)|{'result','phase'}
            or r['result'] not in ('PASS','UNVERIFIED') or r['phase'] not in ('init','manual','timer','cancel','unknown','complete')
            or any(type(r[k]) is not bool for k in FLAGS)
            or any(type(r[k]) is not int or not 0<=r[k]<=cap for k,cap in COUNTS.items())):raise ValueError('native_reader/schema')
    if r['result']=='PASS':
        needed=FLAGS-{'pending_reopened'} if mode=='live' else {'reader_from_shelf','pending_reopened'}
        if (r['phase']!='complete' or r['failed_line'] or r['web_posts'] or not all(r[k] for k in needed)
                or r['native_posts']!=(3 if mode=='live' else 0)):raise ValueError('native_reader/incomplete')
    return r


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--koreader',required=True,type=Path);p.add_argument('--candidate',required=True,type=Path)
    p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167)
    a=p.parse_args(argv);runtime=a.koreader.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file()
            or not all(1<=n<=4096 for n in (a.width,a.height,a.dpi))):p.error('bounded Linux runtime required')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):p.error('tmpfs required')
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    from process_loss_runtime import enable_subreaper
    enable_subreaper()
    report=dict(result='UNVERIFIED',synthetic_only=True,account_data_posts=0,tmpfs_profile=True,profile_removed=False,
                offline_requests=0,stages=[],installed=None,server_posts=0,counts_preserved=False,error='none')
    root=server=None
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-reader-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(a.candidate,profile/'plugins')
            server=NativeReaderServer();threading.Thread(target=server.serve_forever,daemon=True).start()
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',
                     EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(a.width),EMULATE_READER_H=str(a.height),EMULATE_READER_DPI=str(a.dpi),
                     WEREAD_NATIVE_READER_PORT=str(server.server_port))
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/native_reader_position_probe.lua'
            for mode in ('live','reopen'):
                before=server.request_totals.copy()
                code,out,repaint=run_child([str(runtime/'luajit'),str(probe),mode],env,b'',runtime,timeout=180)
                stage=decode(out,mode);report['stages'].append(stage)
                if mode=='reopen':
                    report['offline_requests']=sum((server.request_totals-before).values())
                    if report['offline_requests']:raise ValueError('native_reader/offline_requests')
                if code or repaint or stage['result']!='PASS':raise ValueError('native_reader/runtime')
            report['installed']=check_installed(a.candidate,profile)
            report['server_posts']=server.native_posts;report['counts_preserved']=server.preserved_counts()
            assert server.native_posts==3 and report['counts_preserved']
            report['result']='PASS'
    except subprocess.TimeoutExpired:report['error']='timeout'
    except Exception as error:
        if re.fullmatch(r'native_reader/[a-z_]+',str(error)):report['error']=str(error)
        else:report['error']='runner'
    finally:
        if server:
            report['server_posts']=server.native_posts;report['counts_preserved']=server.preserved_counts()
            server.shutdown();server.server_close()
        report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report,indent=2));return int(report['result']!='PASS' or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
