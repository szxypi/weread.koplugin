#!/usr/bin/env python3
"""Opt-in synthetic native private-reading UI, no public Internet/account."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile
from run_persistent_ui_probe import extract_candidate,run_child

FRAME=b'\nWEREAD_PRIVATE_UI_RESULT='


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args();root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False);repo=Path(__file__).resolve().parent.parent
    candidate=root/'candidate.zip';subprocess.run(['bash',str(repo/'scripts/package_release.sh'),str(candidate)],check=True,capture_output=True)
    report=dict(result='UNVERIFIED',profile_removed=False,installed_bytes_match=False,stages=[])
    temporary=None
    try:
        with tempfile.TemporaryDirectory(prefix='weread-private-',dir='/dev/shm') as temporary:
            profile=Path(temporary)/'profile';(profile/'plugins').mkdir(parents=True);xdg=Path(temporary)/'xdg';xdg.mkdir(mode=0o700)
            extract_candidate(candidate,profile/'plugins');shots=root/'screenshots';shots.mkdir()
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),WEREAD_PRIVATE_SHOTS=str(shots))
            for mode in ('live','reopen'):
                code,out,repaint=run_child([str(args.koreader.resolve()/'luajit'),str(repo/'spec/koreader/shelf_flag_change_ui_probe.lua'),mode],env,b'',args.koreader.resolve(),timeout=300)
                if len(out)>4*1024*1024 or out.count(FRAME)!=1:raise ValueError('native_frame')
                stage=json.loads(out.split(FRAME)[1]);report['stages'].append(stage)
                if code or repaint or stage['result']!='PASS':raise ValueError('native_acceptance')
            with zipfile.ZipFile(candidate) as archive:
                for item in archive.infolist():
                    if not item.is_dir():assert (profile/'plugins'/item.filename).read_bytes()==archive.read(item)
            report.update(result='PASS',installed_bytes_match=True)
    except Exception:pass
    finally:
        report['profile_removed']=temporary is not None and not Path(temporary).exists()
        (root/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report));return int(report['result']!='PASS' or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
