#!/usr/bin/env python3
"""Actual ReaderUI prewrite renewal against a loopback-only fixture."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
import threading
from native_source_recovery_fixture import NativeRecoveryServer,MODES
from run_native_reader_position import FRAME,FLAGS,COUNTS
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate,run_child

CASES=MODES
RECOVERY_FLAGS={'confirmed','fresh_source','closed','cancelled','save_only','unknown_not_replayed','local_kept','renewal_pending','no_closed_document_calls','workers_reaped','timer_triggered'}
RECOVERY_COUNTS={'grant_revision':3,'source_passes':2,'auth_posts':1,'expired_responses':2,'failed_line':10000}
SUCCESS=('snapshot','prewrite','feature','save','save-sync','close-snapshot','close-prewrite','timer-snapshot','timer-prewrite')
CANCELLED=('cancel','offline','account','suspend')


def decode(raw,kind):
    if kind not in CASES or not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('native_recovery/frame')
    r=json.loads(raw.split(FRAME)[1]);expected=FLAGS|set(COUNTS)|{'result','phase','recovery_case'}
    if not isinstance(r,dict) or set(r)!=expected:raise ValueError('native_recovery/schema')
    a=r['recovery_case']
    if (not isinstance(a,dict) or set(a)!=RECOVERY_FLAGS|set(RECOVERY_COUNTS)|{'kind'} or a['kind']!=kind
            or any(type(a[k]) is not bool for k in RECOVERY_FLAGS) or any(type(a[k]) is not int or not 0<=a[k]<=cap for k,cap in RECOVERY_COUNTS.items())
            or r['result'] not in ('PASS','UNVERIFIED') or r['phase'] not in ('init','manual','timer','cancel','unknown','complete')
            or any(type(r[k]) is not bool for k in FLAGS) or any(type(r[k]) is not int or not 0<=r[k]<=cap for k,cap in COUNTS.items())):raise ValueError('native_recovery/schema')
    success=kind in SUCCESS
    pending=kind in (*CANCELLED,'unknown','foreign')
    if r['result']=='PASS' and (r['phase']!='complete' or r['failed_line'] or a['failed_line'] or r['web_posts']
            or not all(r[k] for k in ('manual','original_local_units','summary_not_in_checkpoints','reader_from_shelf','source_workers','workers_reaped','parent_only_document'))
            or any(r[k] for k in ('timed','unknown_not_replayed','pending_reopened','timer_cancelled'))
            or not a['no_closed_document_calls'] or not a['workers_reaped'] or a['confirmed']!=success or a['fresh_source']!=success
            or a['closed']!=kind.startswith('close-') or a['cancelled']!=(kind in CANCELLED) or a['save_only']!=(kind in ('save','save-sync'))
            or a['timer_triggered']!=kind.startswith('timer-')
            or a['unknown_not_replayed']!=(kind=='post') or a['local_kept']!=(not success and kind!='post')
            or a['renewal_pending']!=pending or a['grant_revision']!=(1 if kind=='post' else 2 if pending else 3)
            or a['source_passes']!=(1 if pending or kind=='post' else 2)
            or a['expired_responses']!=(2 if kind=='second' else 1)
            or kind not in CANCELLED and a['auth_posts']!=int(kind!='post') or r['native_posts']!=(2 if success or kind=='post' else 1)):
        raise ValueError('native_recovery/incomplete')
    return r


def check_server(server,stage,kind):
    if (kind not in CASES or server.native_posts!=(2 if kind in SUCCESS or kind=='post' else 1)
            or server.auth_posts!=stage['recovery_case']['auth_posts']
            or server.expiries!=stage['recovery_case']['expired_responses']
            or not 0<=server.auth_posts<=1 or not server.preserved_counts()):
        raise ValueError('native_recovery/server')


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--koreader',required=True,type=Path);p.add_argument('--candidate',required=True,type=Path)
    p.add_argument('--case',choices=CASES,default='snapshot');p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167)
    a=p.parse_args(argv);runtime=a.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not all(1<=n<=4096 for n in (a.width,a.height,a.dpi)):p.error('bounded Linux runtime required')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):p.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report=dict(result='UNVERIFIED',case=a.case,synthetic_only=True,account_data_posts=0,profile_removed=False,stages=[],
                server_posts=0,authentication_posts=0,expired_responses=0,counts_preserved=False,offline_requests=0,installed=None,error='none')
    root=server=None
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-reader-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(a.candidate,profile/'plugins')
            server=NativeRecoveryServer();threading.Thread(target=server.serve_forever,daemon=True).start()
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                     EMULATE_READER_W=str(a.width),EMULATE_READER_H=str(a.height),EMULATE_READER_DPI=str(a.dpi),
                     WEREAD_NATIVE_READER_PORT=str(server.server_port),WEREAD_NATIVE_RECOVERY_CASE=a.case)
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/native_reader_position_probe.lua'
            code,out,repaint=run_child([str(runtime/'luajit'),str(probe),'recovery'],env,b'',runtime,timeout=180)
            stage=decode(out,a.case);report['stages'].append(stage)
            if code or repaint or stage['result']!='PASS':raise ValueError('native_recovery/runtime')
            report['installed']=check_installed(a.candidate,profile)
            check_server(server,stage,a.case)
            report['result']='PASS'
    except subprocess.TimeoutExpired:report['error']='timeout'
    except Exception as error:
        import re
        report['error']=str(error) if re.fullmatch('native_recovery/[a-z_]+',str(error)) else 'runner'
    finally:
        if server:
            report['server_posts']=server.native_posts;report['authentication_posts']=server.auth_posts;report['expired_responses']=server.expiries;report['counts_preserved']=server.preserved_counts();server.shutdown();server.server_close()
        report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report,indent=2));return int(report['result']!='PASS' or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
