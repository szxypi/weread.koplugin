#!/usr/bin/env python3
"""Packaged KOReader personal upload against a fail-closed synthetic server."""
import argparse,os,subprocess,threading
from pathlib import Path
from mock_weread import MockServer,prepare
from synthetic_upload_rich_pdf import build as build_pdf

REPO=Path(__file__).resolve().parent.parent
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--koreader',type=Path,required=True);p.add_argument('--run-dir',type=Path,required=True)
    p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167);a=p.parse_args()
    if min(a.width,a.height,a.dpi)<=0:p.error('positive screen dimensions and DPI required')
    root,runtime=a.run_dir.resolve(),a.koreader.resolve();server=MockServer(0)
    try:
        prepare(root,runtime,server.server_port,a.width,a.height,a.dpi);(root/'xdg').mkdir(mode=0o700)
        (root/'profile/SyntheticUpload.pdf').write_bytes(build_pdf())
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        env=os.environ|dict(KO_HOME=str(root/'profile'),WEREAD_EVIDENCE=str(root/'evidence'),XDG_RUNTIME_DIR=str(root/'xdg'),
            LD_LIBRARY_PATH=str(runtime/'libs'),SDL_VIDEODRIVER='dummy',
            WEREAD_MOCK_PORT=str(server.server_port),EMULATE_READER='1',EMULATE_READER_W=str(a.width),EMULATE_READER_H=str(a.height),
            EMULATE_READER_DPI=str(a.dpi),EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8')
        log=root/'evidence/runtime.log'
        try:
            with log.open('w') as out:
                result=subprocess.run(['./luajit',str(REPO/'spec/koreader/personal_upload_smoke.lua')],cwd=runtime,env=env,
                    stdout=out,stderr=subprocess.STDOUT,timeout=120)
            if result.returncode:print(log.read_text());raise SystemExit(result.returncode)
            assert server.request_totals[('/cos/getcredential','')]==4
            assert server.request_totals[('/synthetic/object','')]==4
            assert server.request_totals[('/cos/notify','')]==4
            assert server.request_totals[('/web/book/read','')]==0
            assert server.request_totals[('/login','native_renewal')]==0
            print(f'PASS: native personal upload and pending recovery; {a.width}x{a.height}')
        finally:server.shutdown();thread.join()
    finally:server.server_close()
if __name__=='__main__':main()
