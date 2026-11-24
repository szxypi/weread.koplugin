#!/usr/bin/env python3
"""Run real shelf search inputs only in a disposable, offline tmpfs profile."""
import argparse
import json
import os
from pathlib import Path
import resource
import sys
import tempfile
import zipfile

from run_persistent_ui_probe import extract_candidate,run_child

FRAME=b'\nWEREAD_OWNER_SHELF_SEARCH='
REPO=Path(__file__).resolve().parent.parent


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,required=True);parser.add_argument('--height',type=int,required=True);parser.add_argument('--dpi',type=int,required=True)
    parser.add_argument('--synthetic',action='store_true');args=parser.parse_args(argv)
    runtime=args.koreader.resolve();candidate=args.candidate.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file() or not candidate.is_file()
            or not all(1<=v<=4096 for v in (args.width,args.height,args.dpi))
            or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
        parser.error('Linux KOReader and tmpfs required')
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));root=None
    report=dict(result='UNVERIFIED',profile_removed=False,private_data_in_report=False,network_requests=0)
    try:
        raw=sys.stdin.buffer.read(4*1024*1024+1)
        if len(raw)>4*1024*1024:raise ValueError('input')
        payload=json.loads(raw);keys={'books','archives','group_label','queries','expected_all','expected_group','group_ids','all_ids','local_cases'}
        if (not isinstance(payload,dict) or set(payload)!=keys or not isinstance(payload['books'],list)
                or not isinstance(payload['archives'],list) or not isinstance(payload['queries'],list) or len(payload['queries'])!=3
                or not isinstance(payload['expected_group'],list) or len(payload['expected_group'])!=3
                or not isinstance(payload['local_cases'],list) or len(payload['local_cases'])!=2):raise ValueError('input')
        with tempfile.TemporaryDirectory(prefix='weread-owner-search-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';plugins=profile/'plugins';plugins.mkdir(parents=True)
            xdg=root/'xdg';xdg.mkdir(mode=0o700);extract_candidate(candidate,plugins)
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            for mode in ('live','reopen'):
                code,out,repaint=run_child([str(runtime/'luajit'),str(REPO/'spec/koreader/owner_shelf_search_ui.lua'),mode],env,raw,runtime,timeout=180)
                if args.synthetic and out.count(FRAME)==1:
                    diagnostic=json.loads(out.split(FRAME)[1].splitlines()[0])
                    if diagnostic.get('result')!='PASS':report['synthetic_failed_line']=diagnostic.get('failed_line',0)
                if code or repaint or out.count(FRAME)!=1:raise ValueError('ui')
                actual=json.loads(out.split(FRAME)[1].splitlines()[0])
                if actual!=dict(result='PASS',mode=mode,queries=4,books=len(payload['all_ids']),
                                group_books=len(payload['group_ids']),network_requests=0,failed_line=0,
                                local_picker_verified=True):raise ValueError('ui')
            with zipfile.ZipFile(candidate) as archive:
                if any((profile/'plugins'/entry.filename).read_bytes()!=archive.read(entry) for entry in archive.infolist() if not entry.is_dir()):
                    raise ValueError('installation')
            report.update(result='PASS',books=len(payload['all_ids']),group_books=len(payload['group_ids']),queries=4,
                          offline_reopen=True,installed_bytes_match=True,local_picker_verified=True)
    except Exception:
        pass
    finally:
        report['profile_removed']=root is not None and not root.exists()
        if not report['profile_removed']:report['result']='UNVERIFIED'
    print(json.dumps(report));return int(report['result']!='PASS')


if __name__=='__main__':raise SystemExit(main())
