#!/usr/bin/env python3
"""Run a read-only owner search UI in an isolated Linux memory profile."""
import argparse
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
import time
import zipfile

from native_trial_pipe import stop
from process_loss_runtime import enable_subreaper,kill_reader_session,session_members
from run_persistent_ui_probe import extract_candidate

FRAME=b'\nWEREAD_OWNER_BOOK_SEARCH_UI='


def reap(session):
    deadline=time.monotonic()+5
    while True:
        members=session_members(session)
        if not members:return
        for pid in members:
            try:
                if os.getsid(pid)==session:os.kill(pid,signal.SIGKILL)
            except ProcessLookupError:pass
            try:os.waitpid(pid,os.WNOHANG)
            except ChildProcessError:pass
        if time.monotonic()>=deadline:raise ValueError('owner_search/workers')
        time.sleep(.01)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report={'result':'UNVERIFIED','profile_removed':False,'installed_bytes_match':False,'account_data_posts':0,'authentication_posts':0}
    root=None
    try:
        runtime=args.koreader.resolve();candidate=args.candidate.resolve()
        if (sys.platform!='linux' or not (runtime/'luajit').is_file() or not candidate.is_file()
                or min(args.width,args.height,args.dpi)<1 or max(args.width,args.height,args.dpi)>4096
                or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
            raise ValueError('owner_search/environment')
        raw=sys.stdin.buffer.read(8*1024*1024+1)
        if not 0<len(raw)<=8*1024*1024:raise ValueError('owner_search/input')
        payload=json.loads(raw)
        if not isinstance(payload,dict):raise ValueError('owner_search/input')
        enable_subreaper()
        with tempfile.TemporaryDirectory(prefix='weread-owner-search-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';plugins=profile/'plugins';plugins.mkdir(parents=True)
            xdg=root/'xdg';xdg.mkdir(mode=0o700)
            extract_candidate(candidate,plugins)
            with zipfile.ZipFile(candidate) as archive:
                for item in archive.infolist():
                    if not item.is_dir() and (plugins/item.filename).read_bytes()!=archive.read(item):raise ValueError('owner_search/package')
            report['installed_bytes_match']=True
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_book_search_ui_probe.lua'
            child=subprocess.Popen([str(runtime/'luajit'),str(probe)],cwd=runtime,env=env,stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
            try:
                out,err=child.communicate(raw,timeout=180)
                if out.count(FRAME)==1:
                    failure=json.loads(out.split(FRAME,1)[1].splitlines()[0])
                    if isinstance(failure,dict) and failure.get('phase') in ('decode','reader','search','navigate'):
                        report['failure_phase']=failure['phase']
                        if failure.get('navigation_diagnostic') in ('unknown','confirm','working','ready_target','ready_no_target','inactive','bind_failed','source_opened','other','locate_failed','position_unavailable','save_failed'):
                            report['navigation_diagnostic']=failure['navigation_diagnostic']
                        if failure.get('failure_detail') in ('unknown','blocked','blocked_catalog','blocked_policy','blocked_search','blocked_other','http_failed','no_catalog','no_search','after_search'):
                            report['failure_detail']=failure['failure_detail']
                if child.returncode or len(out)>8*1024*1024 or out.count(FRAME)!=1 or b'[WeRead] forceRePaint failed:' in out+err:
                    raise ValueError('owner_search/native')
                value=json.loads(out.split(FRAME,1)[1].splitlines()[0])
                flags=('native_menu','search_result_verified','source_navigation','workers_reaped')
                missing=payload.get('download_missing') is True
                extra={'download_confirmed','cancel_without_download','downloaded_source_verified','credential_audit',
                    'download_gets','catalog_posts','content_posts'} if missing else set()
                catalog_missing=payload.get('catalog_missing') is True
                if catalog_missing:extra|={'catalog_restored','catalog_gets','catalog_read_posts','credential_audit'}
                if (not isinstance(value,dict) or set(value)!={'result',*flags,'account_gets','search_gets','denied_requests',*extra}
                        or value['result']!='PASS' or any(value[k] is not True for k in flags)
                        or type(value['account_gets']) is not int or value['account_gets']<1
                        or type(value['search_gets']) is not int or value['account_gets']!=value['search_gets']
                        or type(value['denied_requests']) is not int or value['denied_requests']!=0):
                    raise ValueError('owner_search/result')
                if missing and (any(value[k] is not True for k in ('download_confirmed','cancel_without_download',
                        'downloaded_source_verified','credential_audit'))
                        or any(type(value[k]) is not int or value[k]<1 for k in ('download_gets','catalog_posts','content_posts'))):
                    raise ValueError('owner_search/download')
                if catalog_missing and (value['catalog_restored'] is not True or value['credential_audit'] is not True
                        or any(type(value[k]) is not int or value[k]<1 for k in ('catalog_gets','catalog_read_posts'))):
                    raise ValueError('owner_search/catalog')
                report.update(result='PASS',ui=value)
            finally:
                if child.poll() is None:
                    try:kill_reader_session(child)
                    except (ProcessLookupError,RuntimeError):pass
                stop(child);reap(child.pid)
    except Exception:
        pass
    finally:report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report));return int(report['result']!='PASS' or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
