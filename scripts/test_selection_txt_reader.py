#!/usr/bin/env python3
"""Run a synthetic TXT selection through packaged KOReader ReaderUI."""
import argparse
import json
import os
from pathlib import Path
import subprocess

from mock_weread import prepare


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167);args=parser.parse_args()
    if min(args.width,args.height,args.dpi)<1:parser.error('invalid screen')
    runtime=args.koreader.resolve();root=args.run_dir.resolve();prepare(root,runtime,1,args.width,args.height,args.dpi)
    (root/'xdg').mkdir(mode=0o700)
    env=os.environ|dict(KO_HOME=str(root/'profile'),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',
        EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),
        EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8')
    command=[str(runtime/'luajit'),str(Path(__file__).resolve().parent.parent/'spec/koreader/selection_txt_reader_probe.lua')]
    marker=b'\nWEREAD_TXT_SELECTION_READER='
    for reopen in (False,True):
        child=subprocess.run(command,cwd=runtime,env=env|dict(WEREAD_TXT_SELECTION_REOPEN='1' if reopen else '0'),
                             stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90)
        if child.returncode or child.stdout.count(marker)!=1:
            (root/'evidence'/('reopen.log' if reopen else 'runtime.log')).write_bytes(child.stdout+child.stderr)
            raise ValueError('txt_selection_reader/runtime')
        value=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
        if value!=dict(result='PASS',native_context=True,raw_range=True,book_bound=True,network_requests=0,reopened=reopen):
            raise ValueError('txt_selection_reader/result')
    print(json.dumps(dict(result='PASS',native_context=True,raw_range=True,offline_reopen=True,network_requests=0)));return 0


if __name__=='__main__':raise SystemExit(main())
