#!/usr/bin/env python3
"""Synthetic UI/worker cancellation, using only a disposable tmpfs profile."""
import argparse
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate
from run_native_thought_trial import stop_reader


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--koreader',required=True,type=Path);p.add_argument('--candidate',required=True,type=Path)
    p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167);a=p.parse_args();runtime=a.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not 1<=min(a.width,a.height,a.dpi)<=max(a.width,a.height,a.dpi)<=4096:p.error('bounded Linux runtime required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    def interrupted(_signal,_frame):raise RuntimeError('native_position_cancel/interrupted')
    signal.signal(signal.SIGTERM,interrupted)
    root=child=None;r={'result':'UNVERIFIED','profile_removed':False,'stage':None,'installed':None}
    try:
        if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):raise ValueError('tmpfs required')
        with tempfile.TemporaryDirectory(prefix='weread-position-cancel-',dir='/dev/shm') as directory:
            root=Path(directory);home=root/'profile';(home/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(a.candidate,home/'plugins')
            env=dict(os.environ,KO_HOME=str(home),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(a.width),EMULATE_READER_H=str(a.height),EMULATE_READER_DPI=str(a.dpi))
            command=[str(runtime/'luajit'),str(Path(__file__).resolve().parent.parent/'spec/koreader/native_position_cancel_probe.lua')]
            child=subprocess.Popen(command,cwd=runtime,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                output=child.communicate(timeout=90)[0];marker=b'\nWEREAD_NATIVE_POSITION_CANCEL='
                if len(output)>65536 or output.count(marker)!=1:raise ValueError('native_position_cancel/output')
                r['stage']=json.loads(output.split(marker)[1]);stage=r['stage']
                if child.returncode or stage.get('result')!='PASS' or len(stage.get('cases',[]))!=4 or not all(stage.get(k) is True for k in ('heartbeat','parent_guard_only','workers_reaped')) or stage.get('account_data_posts')!=0:raise ValueError('native_position_cancel/stage')
            finally:stop_reader(child);child=None
            r.update(result='PASS',installed=check_installed(a.candidate,home))
    except Exception:pass
    finally:
        if child is not None:stop_reader(child)
        r['profile_removed']=root is not None and not root.exists()
    print(json.dumps(r,indent=2));return int(r['result']!='PASS' or not r['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
