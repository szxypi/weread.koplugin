#!/usr/bin/env python3
"""Run packaged article-link import and fresh offline reopen in KOReader."""
import argparse,os,subprocess,threading
from pathlib import Path
from mock_weread import MockServer,prepare

REPO=Path(__file__).resolve().parent.parent
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--koreader',type=Path,required=True);p.add_argument('--run-dir',type=Path,required=True)
    p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167)
    a=p.parse_args()
    if min(a.width,a.height,a.dpi)<=0:p.error('positive screen dimensions and DPI required')
    root,runtime=a.run_dir.resolve(),a.koreader.resolve();server=MockServer(0)
    try:
        prepare(root,runtime,server.server_port,a.width,a.height,a.dpi);(root/'xdg').mkdir(mode=0o700)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        env=os.environ|dict(KO_HOME=str(root/'profile'),WEREAD_EVIDENCE=str(root/'evidence'),XDG_RUNTIME_DIR=str(root/'xdg'),
            WEREAD_MOCK_PORT=str(server.server_port),EMULATE_READER='1',EMULATE_READER_W=str(a.width),
            EMULATE_READER_H=str(a.height),EMULATE_READER_DPI=str(a.dpi),EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8')
        fixture=REPO/'spec/koreader/mp_link_smoke.lua'
        try:
            for reopen in (False,True):
                before=server.request_totals.copy()
                log=root/'evidence'/('offline.log' if reopen else 'runtime.log')
                with log.open('w') as out:
                    result=subprocess.run(['./luajit',str(fixture)],cwd=runtime,env=env|({'WEREAD_MP_LINK_REOPEN':'1'} if reopen else {}),
                        stdout=out,stderr=subprocess.STDOUT,timeout=120)
                if result.returncode:
                    print(log.read_text());raise SystemExit(result.returncode)
                if reopen:assert server.request_totals==before,'offline reopen sent HTTP'
            assert server.request_totals[('/mp/getreviewid','')]==1,'lookup count mismatch'
            assert server.request_totals[('/web/mp/content','')]==2,'title and article body count mismatch'
            assert server.request_totals[('/shelf/add','')]==server.request_totals[('/shelf/delete','')]==1,'subscription roundtrip count mismatch'
            assert server.request_totals[('/web/book/read','')]==0,'reading state changed'
            print(f'PASS: packaged article import and offline reopen; {a.width}x{a.height}')
        finally:server.shutdown();thread.join()
    finally:server.server_close()
if __name__=='__main__':main()
