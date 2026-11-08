#!/usr/bin/env python3
"""Check the packaged translation display core with real CRE, not reader UI."""
import argparse
import os
from pathlib import Path
import subprocess
import threading
from mock_weread import MockServer,prepare

REPO=Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args()
    if min(args.width,args.height,args.dpi)<=0: parser.error('screen dimensions and DPI must be positive')
    root,runtime=args.run_dir.resolve(),args.koreader.resolve()
    server=MockServer(0)
    try:
        prepare(root,runtime,server.server_port,args.width,args.height,args.dpi)
        (root/'xdg').mkdir(mode=0o700)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        env=os.environ|dict(KO_HOME=str(root/'profile'),WEREAD_EVIDENCE=str(root/'evidence'),XDG_RUNTIME_DIR=str(root/'xdg'),
            EMULATE_READER='1',EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),
            EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8')
        log=root/'evidence/runtime.log'
        try:
            with log.open('w') as out:
                result=subprocess.run(['./luajit',str(REPO/'spec/koreader/translation_display_smoke.lua')],
                    cwd=runtime,env=env,stdout=out,stderr=subprocess.STDOUT,timeout=90)
        finally:
            server.shutdown();thread.join()
        if result.returncode==0:
            assert b'forceRePaint failed' not in log.read_bytes(),'native repaint failed'
            assert not server.events,'display core attempted network requests'
        print(('PASS' if result.returncode==0 else 'FAIL')+': '+str(log))
        raise SystemExit(result.returncode)
    finally: server.server_close()


if __name__=='__main__': main()
