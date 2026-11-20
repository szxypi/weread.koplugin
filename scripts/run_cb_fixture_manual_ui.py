#!/usr/bin/env python3
"""Isolated tmpfs ReaderUI runner for one owned, self-authored CB fixture."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
import zipfile

from native_trial_pipe import stop
from process_loss_runtime import enable_subreaper,kill_reader_session
from run_owner_book_search_ui import reap
from run_persistent_ui_probe import extract_candidate


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report=dict(result='UNVERIFIED',profile_removed=False,installed_bytes_match=False);root=None
    try:
        runtime=args.koreader.resolve();candidate=args.candidate.resolve()
        if (sys.platform!='linux' or not (runtime/'luajit').is_file() or not candidate.is_file()
                or min(args.width,args.height,args.dpi)<1 or max(args.width,args.height,args.dpi)>4096
                or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
            raise ValueError('environment')
        payload=sys.stdin.buffer.read(8*1024*1024+1)
        if not 0<len(payload)<=8*1024*1024:raise ValueError('input')
        decoded=json.loads(payload)
        if not isinstance(decoded,dict) or not isinstance(decoded.get('cookies'),dict):raise ValueError('input')
        if decoded.get('armed') is not None and type(decoded['armed']) is not bool:raise ValueError('input')
        dry=decoded.get('armed') is False
        timed=decoded.get('timer') is True
        closing=decoded.get('close') is True
        reading_time=decoded.get('time') is True
        if sum((timed,closing,reading_time))>1 or dry and (timed or closing or reading_time):raise ValueError('input')
        secrets=[value.encode() for key,value in decoded['cookies'].items()
                 if key!='wr_vid' and isinstance(value,str) and len(value)>=8]
        if not secrets:raise ValueError('input')
        del decoded;enable_subreaper()
        with tempfile.TemporaryDirectory(prefix='weread-cb-manual-fixture-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';plugins=profile/'plugins';plugins.mkdir(parents=True)
            xdg=root/'xdg';xdg.mkdir(mode=0o700);extract_candidate(candidate,plugins)
            if os.environ.get('WEREAD_FIXTURE_SYNTHETIC')=='1':
                port=int(os.environ.get('WEREAD_FIXTURE_MOCK_PORT','0'))
                if not 1<=port<=65535:raise ValueError('mock')
                (profile/'settings').mkdir(exist_ok=True)
                (profile/'settings/weread-environment.lua').write_text(
                    f'return {{ enabled = true, host = "127.0.0.1", port = {port} }}\n')
            with zipfile.ZipFile(candidate) as archive:
                for item in archive.infolist():
                    if not item.is_dir() and (plugins/item.filename).read_bytes()!=archive.read(item):raise ValueError('candidate')
            report['installed_bytes_match']=True
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),EMULATE_READER='1',EMULATE_BW_SCREEN='1',
                EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/cb_fixture_manual_ui.lua'
            for reopened in ((False,) if dry else (False,True)):
                child=subprocess.Popen([str(runtime/'luajit'),str(probe)],cwd=runtime,
                    env=env | {'WEREAD_FIXTURE_CB_REOPEN':'1' if reopened else '0'},stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
                try:
                    out,err=child.communicate(payload,timeout=360);marker=b'\nWEREAD_CB_FIXTURE_MANUAL_UI='
                    if out.count(marker)==1:
                        value=json.loads(out.split(marker,1)[1].splitlines()[0])
                        if value.get('phase') in ('decode','prepare','choice','upload','timer','close','time','reopen'):report['failure_phase']=value['phase']
                        if type(value.get('failure_line')) is int:report['failure_line']=value['failure_line']
                    if child.returncode or len(out)>8*1024*1024 or out.count(marker)!=1 or b'[WeRead] forceRePaint failed:' in out+err:
                        raise ValueError('native')
                    expected=(dict(result='DRY_RUN',native_choice=True,write_blocked=True,writes=0,denied=1) if dry else
                        dict(result='PASS',fresh_process=True,offline=True,pending_cleared=True,journal_cleared=True,requests=0)
                        if reopened else dict(result='PASS',native_choice=True,actual_source=True,upload_confirmed=True,pending_cleared=True,
                            journal_cleared=True,automatic_disabled=not (timed or closing or reading_time),timer_verified=timed,writes=3 if timed or closing or reading_time else 2,denied=0))
                    if closing and not reopened:expected['close_verified']=True
                    if reading_time and not reopened:expected['time_verified']=True
                    if value!=expected:raise ValueError('result')
                    for path in profile.rglob('*'):
                        if path.is_file() and not path.is_symlink() and any(secret in path.read_bytes() for secret in secrets):
                            raise ValueError('credential_storage')
                finally:
                    if child.poll() is None:
                        try:kill_reader_session(child)
                        except (ProcessLookupError,RuntimeError):pass
                    stop(child);reap(child.pid)
            if dry:report.update(result='DRY_RUN',native_choice=True,write_blocked=True,writes=0,denied=1,credentials_not_persisted=True)
            else:report.update(result='PASS',native_choice=True,actual_source=True,upload_confirmed=True,fresh_process=True,
                          pending_cleared=True,journal_cleared=True,automatic_disabled=not (timed or closing or reading_time),writes=3 if timed or closing or reading_time else 2,denied=0,credentials_not_persisted=True)
            if timed:report['timer_verified']=True
            if closing:report['close_verified']=True
            if reading_time:report['time_verified']=True
    except Exception:
        pass
    finally:report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report));return int(report['result'] not in ('PASS','DRY_RUN') or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
