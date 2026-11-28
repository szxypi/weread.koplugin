#!/usr/bin/env python3
"""Exercise a >8 MiB upload in packaged native UI against synthetic HTTP."""
import argparse,os,subprocess,threading
from pathlib import Path
from mock_weread import MockServer,prepare

REPO=Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args();root=args.run_dir.resolve();runtime=args.koreader.resolve();server=MockServer(0)
    try:
        prepare(root,runtime,server.server_port,args.width,args.height,args.dpi);(root/'xdg').mkdir(mode=0o700)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        env=os.environ|dict(KO_HOME=str(root/'profile'),XDG_RUNTIME_DIR=str(root/'xdg'),WEREAD_MOCK_PORT=str(server.server_port),
            LD_LIBRARY_PATH=str(runtime/'libs'),SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_READER_W=str(args.width),
            EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8')
        try:
            result=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/personal_upload_large_smoke.lua')],cwd=runtime,env=env,
                stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=150)
            if result.returncode:raise RuntimeError(result.stdout[-4000:])
            for route in ('/cos/getcredential','/synthetic/object','/cos/notify'):assert server.request_totals[(route,'')]==1
            assert server.request_totals[('/login','native_renewal')]==0
            print(f'PASS: streamed native 9 MiB upload, {args.width}x{args.height}')
        finally:server.shutdown();thread.join()
    finally:server.server_close()


if __name__=='__main__':main()
