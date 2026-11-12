#!/usr/bin/env python3
"""Check packaged local translation display with real CRE or full ReaderUI."""
import argparse
import os
from pathlib import Path
import subprocess
import threading
import zipfile
import warnings
from mock_weread import MockServer,prepare

REPO=Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--reader',action='store_true',help='exercise actual reader menus, persistence and reload')
    args=parser.parse_args()
    if min(args.width,args.height,args.dpi)<=0: parser.error('screen dimensions and DPI must be positive')
    root,runtime=args.run_dir.resolve(),args.koreader.resolve()
    server=MockServer(0)
    try:
        prepare(root,runtime,server.server_port,args.width,args.height,args.dpi)
        if args.reader:
            container='<container><rootfiles><rootfile media-type="application/oebps-package+xml" full-path="OPS/book.opf"/></rootfiles></container>'
            opf='<package unique-identifier="book"><metadata><dc:identifier id="book">weread-900001-test</dc:identifier></metadata><manifest><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>'
            bodies=[('OPS/b.xhtml','<html><body><p>Source B</p><p class="wr-translation">Translation B</p></body></html>'),
                    ('OPS/a.xhtml','<html><body><p>Source A</p><p class="wr-translation">Translation A</p></body></html>')]
            for variant in ('valid','duplicate','missing','wrong-book'):
                entries=[('META-INF/container.xml',container),('OPS/book.opf',opf)]+bodies
                if variant=='duplicate': entries.append(bodies[-1])
                if variant=='missing': entries=entries[:-1]
                if variant=='wrong-book': entries[1]=(entries[1][0],opf.replace('weread-900001-','weread-900002-'))
                with warnings.catch_warnings():
                    warnings.simplefilter('ignore',UserWarning)
                    with zipfile.ZipFile(root/'books'/('archive-'+variant+'.epub'),'w') as package:
                        for name,value in entries: package.writestr(name,value)
        (root/'xdg').mkdir(mode=0o700)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        env=os.environ|dict(KO_HOME=str(root/'profile'),WEREAD_EVIDENCE=str(root/'evidence'),XDG_RUNTIME_DIR=str(root/'xdg'),
            EMULATE_READER='1',EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),
            EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8')
        log=root/'evidence/runtime.log'
        try:
            with log.open('w') as out:
                probe='translation_reader_smoke.lua' if args.reader else 'translation_display_smoke.lua'
                result=subprocess.run(['./luajit',str(REPO/'spec/koreader'/probe)],
                    cwd=runtime,env=env,stdout=out,stderr=subprocess.STDOUT,timeout=120)
        finally:
            server.shutdown();thread.join()
        if result.returncode==0:
            assert b'forceRePaint failed' not in log.read_bytes(),'native repaint failed'
            assert not server.events,'display core attempted network requests'
        print(('PASS' if result.returncode==0 else 'FAIL')+': '+str(log))
        raise SystemExit(result.returncode)
    finally: server.server_close()


if __name__=='__main__': main()
