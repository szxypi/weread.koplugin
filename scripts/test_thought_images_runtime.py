#!/usr/bin/env python3
"""Synthetic installed KOReader image viewer and account-local offline cache."""
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
    if args.public_stdin:
        if len(raw)>16384:raise ValueError('input_limit')
        payload=json.loads(raw)
        if set(payload)!={'url','sha256'}:raise ValueError('input_shape')
    runtime=args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='thought-images-package-',dir='/dev/shm') as package:
        candidate=Path(package)/'candidate.zip'
        subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            with tempfile.TemporaryDirectory(prefix='thought-images-ui-',dir='/dev/shm') as directory:
                root=Path(directory);(root/'plugins').mkdir();(root/'xdg').mkdir(mode=0o700)
                extract_candidate(candidate,root/'plugins')
                env=dict(os.environ,KO_HOME=str(root),XDG_RUNTIME_DIR=str(root/'xdg'),LD_LIBRARY_PATH=str(runtime/'libs'),
                    SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                    EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi),WEREAD_SYNTHETIC='1')
                for mode in (('public','public-offline') if args.public_stdin else ('live','offline','foreign','corrupt','quota')):
                    result=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/thought_images_probe.lua'),mode],
                        env=env,cwd=runtime,input=raw,capture_output=True,timeout=90)
                    if result.returncode or ('WEREAD_THOUGHT_IMAGE=PASS:'+mode).encode() not in result.stdout:
                        if args.public_stdin:raise AssertionError((mode,'public image verification failed'))
                        raise AssertionError((mode,result.stdout[-4000:],result.stderr[-4000:]))
            print('PASS:',width,height,'public image online and offline' if args.public_stdin else
                'online viewer, offline reopen, account isolation, corruption and quotas')


if __name__=='__main__':main()
