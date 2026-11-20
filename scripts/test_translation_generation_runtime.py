#!/usr/bin/env python3
"""Run the translation-request menu in the real KOReader reader, offline."""
import argparse,os,subprocess,threading
from pathlib import Path
from mock_weread import MockServer,prepare

REPO=Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',required=True,type=Path)
    parser.add_argument('--run-dir',required=True,type=Path)
    parser.add_argument('--integrated',action='store_true')
    parser.add_argument('--cancel-after-write',action='store_true')
    parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args()
    if args.cancel_after_write and not args.integrated:parser.error('cancellation scenario requires --integrated')
    if min(args.width,args.height,args.dpi)<=0:parser.error('screen dimensions must be positive')
    root,runtime=args.run_dir.resolve(),args.koreader.resolve()
    server=MockServer(0)
    if args.integrated:
        raw='<html><body><p>'+('Synthetic native reading paragraph. '*12)+'</p><p class="wr-translation">合成译文</p></body></html>'
        server.chapter_source=lambda uid,revision=None:raw
    try:
        prepare(root,runtime,server.server_port,args.width,args.height,args.dpi)
        (root/'xdg').mkdir(mode=0o700)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        env=os.environ|dict(KO_HOME=str(root/'profile'),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',
            EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),
            EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',WEREAD_GENERATION_INTEGRATED='1' if args.integrated else '0',
            WEREAD_GENERATION_CANCEL='1' if args.cancel_after_write else '0')
        result=subprocess.run(['./luajit',str(REPO/'spec/koreader/translation_generation_ui_smoke.lua')],
            cwd=runtime,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
        if result.returncode or b'PASS: native translation request menu' not in result.stdout or b'forceRePaint failed' in result.stdout:
            print(result.stdout.decode(errors='replace')[-12000:]);return 1
        if not args.integrated and server.events:raise AssertionError('synthetic UI unexpectedly accessed the network')
        if args.integrated and not args.cancel_after_write:
            if not server.events:raise AssertionError('translated copy was not downloaded')
            for event in server.events:
                path=event['path'];method=event['method']
                if not (method=='GET' and path.startswith('/web/reader/') or method=='POST' and
                    (path=='/web/book/chapterInfos' or path in ('/web/book/chapter/e_0','/web/book/chapter/e_1','/web/book/chapter/e_2','/web/book/chapter/e_3'))):
                    raise AssertionError('download attempted an account mutation')
        if args.cancel_after_write and server.events:raise AssertionError('canceled generation downloaded a copy')
        name='cancel after dispatch' if args.cancel_after_write else 'integrated flow' if args.integrated else 'menu and worker'
        print('PASS: native translation request %s at %sx%s' % (name,args.width,args.height));return 0
    finally:
        server.shutdown();server.server_close()


if __name__=='__main__':raise SystemExit(main())
