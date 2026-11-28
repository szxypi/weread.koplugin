#!/usr/bin/env python3
"""Packaged native batch, offline restart, account isolation and quota."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from run_persistent_ui_probe import extract_candidate

REPO=Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--public-stdin',action='store_true');args=parser.parse_args()
    raw=sys.stdin.buffer.read(16385) if args.public_stdin else b''
    if args.public_stdin and (len(raw)>16384 or set(json.loads(raw))!={'url','sha256'}):raise ValueError('input_scope')
    runtime=args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='note-image-bulk-package-',dir='/dev/shm') as package:
        candidate=Path(package)/'candidate.zip'
        subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            with tempfile.TemporaryDirectory(prefix='note-image-bulk-ui-',dir='/dev/shm') as directory:
                root=Path(directory);(root/'plugins').mkdir();(root/'xdg').mkdir(mode=0o700)
                extract_candidate(candidate,root/'plugins')
                env=dict(os.environ,KO_HOME=str(root),XDG_RUNTIME_DIR=str(root/'xdg'),LD_LIBRARY_PATH=str(runtime/'libs'),
                    SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                    EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi),WEREAD_SYNTHETIC='1')
                if args.public_stdin:env['WEREAD_PUBLIC_NOTE_IMAGE']='1'
                for mode in ('online','offline','foreign','changed','quota','cancel','clear_failure','clear','empty'):
                    child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/notebook_image_bulk_probe.lua'),mode],
                        cwd=runtime,env=env,input=raw,capture_output=True,timeout=90)
                    if child.returncode or ('WEREAD_NOTE_IMAGE_BULK=PASS:'+mode).encode() not in child.stdout:
                        if args.public_stdin:raise AssertionError((mode,'public image verification failed'))
                        raise AssertionError((mode,child.stdout[-4000:],child.stderr[-4000:]))
            print('PASS:',width,height,'native image batch, offline, isolation, quota and cancellation')


if __name__=='__main__':main()
