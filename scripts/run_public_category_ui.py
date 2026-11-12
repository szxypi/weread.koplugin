#!/usr/bin/env python3
"""Two signed-out native processes; isolated tmpfs, no credentials accepted."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

from public_category_ui_contract import FRAME,PRIVATE,ERRORS,decode_stage
from run_persistent_ui_probe import extract_candidate,run_child


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--mock-port',type=int)
    args=parser.parse_args();runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or min(args.width,args.height,args.dpi)<1:parser.error('requires Linux and built runtime')
    if args.mock_port is not None and not 1<=args.mock_port<=65535:parser.error('invalid mock port')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    report=dict(result='UNVERIFIED',tmpfs_profile=True,profile_removed=False,installed_bytes_match=False,installed_files=0,stages=[],runner_error='none')
    root=None;private=[]
    try:
        raw=sys.stdin.buffer.read(2*1024*1024+1)
        if len(raw)>2*1024*1024:raise ValueError('input_limit')
        payload=json.loads(raw)
        if set(payload)!={'catalog','samples'} or not 3<=len(payload['samples'])<=6:raise ValueError('input_limit')
        with tempfile.TemporaryDirectory(prefix='weread-category-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                     EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            if args.mock_port:env['WEREAD_CATEGORY_MOCK']=str(args.mock_port)
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/public_category_probe.lua'
            for mode in ('live','reopen'):
                code,out,repaint=run_child([str(runtime/'luajit'),str(probe),mode],env,raw,runtime,timeout=180)
                stage,data=decode_stage(out,mode,len(payload['samples'])+1);report['stages'].append(stage);private.append(data)
                if code or repaint or stage['result']!='PASS':raise ValueError('stage_unverified')
            with zipfile.ZipFile(args.candidate) as archive:
                if archive.testzip() is not None:raise ValueError('candidate_layout')
                for item in archive.infolist():
                    if item.is_dir():continue
                    path=profile/'plugins'/item.filename
                    if path.is_symlink() or not path.is_file() or archive.read(item)!=path.read_bytes():raise ValueError('candidate_layout')
                    report['installed_files']+=1
            report.update(result='PASS',installed_bytes_match=True)
    except subprocess.TimeoutExpired:report['runner_error']='child_timeout'
    except Exception as error:report['runner_error']=str(error) if str(error) in ERRORS else 'runner_exception'
    finally:report['profile_removed']=root is not None and not root.exists()
    sys.stdout.buffer.write(PRIVATE+json.dumps(private).encode()+FRAME+json.dumps(report).encode()+b'\n')
    return 0 if report['result']=='PASS' and report['profile_removed'] else 1


if __name__=='__main__':raise SystemExit(main())
