#!/usr/bin/env python3
"""Run real-source offline search with an isolated, ephemeral memory profile."""
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
from process_loss_runtime import enable_subreaper, kill_reader_session
from run_owner_book_search_ui import reap
from run_persistent_ui_probe import extract_candidate


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--full',action='store_true')
    args=parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report={'result':'UNVERIFIED','profile_removed':False,'installed_bytes_match':False}
    root=None
    try:
        runtime=args.koreader.resolve();candidate=args.candidate.resolve()
        if (sys.platform!='linux' or not (runtime/'luajit').is_file() or not candidate.is_file()
                or min(args.width,args.height,args.dpi)<1 or max(args.width,args.height,args.dpi)>4096
                or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
            raise ValueError('environment')
        payload=sys.stdin.buffer.read(8*1024*1024+1)
        if not 0<len(payload)<=8*1024*1024 or not isinstance(json.loads(payload),dict):raise ValueError('input')
        enable_subreaper()
        with tempfile.TemporaryDirectory(prefix='weread-catalog-free-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';plugins=profile/'plugins';plugins.mkdir(parents=True)
            xdg=root/'xdg';xdg.mkdir(mode=0o700)
            extract_candidate(candidate,plugins)
            with zipfile.ZipFile(candidate) as archive:
                for item in archive.infolist():
                    if not item.is_dir() and (plugins/item.filename).read_bytes()!=archive.read(item):raise ValueError('candidate')
            report['installed_bytes_match']=True
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),EMULATE_READER='1',EMULATE_BW_SCREEN='1',
                EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),
                EMULATE_READER_DPI=str(args.dpi),WEREAD_OWNER_FULL='1' if args.full else '0')
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_catalog_free_search_ui.lua'
            for reopened in (False,True):
                child=subprocess.Popen([str(runtime/'luajit'),str(probe)],cwd=runtime,
                    env=env | {'WEREAD_OWNER_UNINDEXED_REOPEN':'1' if reopened else '0'},stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
                try:
                    out,err=child.communicate(payload,timeout=360)
                    marker=b'\nWEREAD_OWNER_CATALOG_FREE_UI='
                    if (child.returncode or len(out)>8*1024*1024 or out.count(marker)!=1
                            or b'[WeRead] forceRePaint failed:' in out+err):raise ValueError('native')
                    value=json.loads(out.split(marker,1)[1].splitlines()[0])
                    expected=dict(result='PASS',prior_position_preserved=True,offline=True)
                    expected['bookshelf_resume' if reopened else 'native_navigation']=True
                    if value!=expected:raise ValueError('result')
                finally:
                    if child.poll() is None:
                        try:kill_reader_session(child)
                        except (ProcessLookupError,RuntimeError):pass
                    stop(child);reap(child.pid)
            report.update(result='PASS',native_navigation=True,bookshelf_resume=True,prior_position_preserved=True,offline=True)
    except Exception:
        pass
    finally:report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report));return int(report['result']!='PASS' or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
