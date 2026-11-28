#!/usr/bin/env python3
"""Read-only live cloud choice and fresh offline process, confined to tmpfs."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
from owner_unstarted_contract import validate_payload,decode
from verify_owner_reading import FRAME
from run_persistent_ui_probe import extract_candidate
from run_owner_reading_probe import check_installed
from run_native_thought_trial import stop_reader


def reader_stage(command,environment,raw,cwd):
    child=subprocess.Popen(command,env=environment,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                           start_new_session=True,cwd=cwd)
    try:
        out,err=child.communicate(raw,timeout=180)
        return child.returncode,out,b'[WeRead] forceRePaint failed:' in out+err
    finally:stop_reader(child)


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--koreader',required=True,type=Path);p.add_argument('--candidate',required=True,type=Path)
    p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167)
    p.add_argument('--mock-port',type=int);a=p.parse_args(argv);runtime=a.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not all(1<=n<=4096 for n in (a.width,a.height,a.dpi)):p.error('bounded Linux runtime required')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):p.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report=dict(result='UNVERIFIED',profile_removed=False,stages=[],installed=None,error='none');private=[];cookies={};root=None
    try:
        raw=sys.stdin.buffer.read(256*1024+1)
        if len(raw)>256*1024:raise ValueError('unstarted/input')
        payload=json.loads(raw);validate_payload(payload,a.mock_port);cookies=payload['cookies']
        with tempfile.TemporaryDirectory(prefix='weread-reading-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(a.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(a.width),EMULATE_READER_H=str(a.height),EMULATE_READER_DPI=str(a.dpi))
            folder=Path(__file__).resolve().parent.parent/'spec/koreader'
            for mode in ('live','reopen'):
                payload['cookies']=cookies
                code,out,repaint=reader_stage([str(runtime/'luajit'),str(folder/'owner_reading_probe.lua'),mode,str(folder/'owner_unstarted_case.lua')],
                    env,json.dumps(payload,ensure_ascii=False).encode(),runtime)
                value=decode(out,payload['vid'],mode);report['stages'].append(value['report']);cookies=value['cookies']
                private.append(value.get('candidate_private'))
                if code or repaint or value['report']['result']!='PASS':raise ValueError('unstarted/runtime')
            report.update(result='PASS',installed=check_installed(a.candidate,profile))
    except Exception as error:
        import re
        report['error']=str(error) if re.fullmatch('unstarted/[a-z_]+',str(error)) else 'runner'
    finally:report['profile_removed']=root is not None and not root.exists()
    sys.stdout.buffer.write(FRAME+json.dumps(dict(report=report,cookies=cookies,candidate_private=private)).encode()+b'\n');sys.stdout.buffer.flush()
    return int(report['result']!='PASS' or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
