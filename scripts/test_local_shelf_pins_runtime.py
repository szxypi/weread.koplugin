#!/usr/bin/env python3
"""Packaged local pin actions, account isolation, SQLite and offline restart."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from mock_weread import prepare


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args();root=args.run_dir.resolve();runtime=args.koreader.resolve()
    prepare(root,runtime,8765,args.width,args.height,args.dpi);(root/'xdg').mkdir(mode=0o700)
    env=os.environ|dict(KO_HOME=str(root/'profile'),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',
        WEREAD_LOCAL_PIN_EVIDENCE=str(root/'evidence'),
        EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),
        EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8')
    probe=Path(__file__).resolve().parent.parent/'spec/koreader/local_shelf_pins_smoke.lua'
    for phase in ('live','reopen','unpin_reopen'):
        log=root/'evidence'/('local-pins-'+phase+'.log')
        with log.open('w') as output:
            child=subprocess.run([str(runtime/'luajit'),str(probe)],cwd=runtime,env=env|dict(WEREAD_LOCAL_PIN_PHASE=phase),
                                 stdout=output,stderr=subprocess.STDOUT,timeout=120)
        raw=log.read_bytes();marker=b'\nWEREAD_LOCAL_PINS='
        if child.returncode or raw.count(marker)!=1:raise ValueError('local pin runtime failed; inspect synthetic log')
        value=json.loads(raw.split(marker,1)[1].splitlines()[0])
        if value!=dict(result='PASS',phase=phase,network_requests=0) or b'[WeRead] forceRePaint failed:' in raw:
            raise ValueError('local pin result mismatch')
    print(json.dumps(dict(result='PASS',width=args.width,height=args.height,offline_reopen=True,network_requests=0)))


if __name__=='__main__':main()
