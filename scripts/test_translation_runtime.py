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
    parser.add_argument('--fetch',action='store_true',help='exercise existing-translation download and offline copy opening')
    parser.add_argument('--fetch-book',action='store_true',help='exercise full-book existing translations and offline chapter navigation')
    parser.add_argument('--annotations',action='store_true',help='exercise annotation copying into the full-book translation')
    parser.add_argument('--hash-storage',action='store_true',help='exercise KOReader hash-based metadata storage')
    parser.add_argument('--dir-storage',action='store_true',help='exercise KOReader centralized metadata storage')
    args=parser.parse_args()
    if min(args.width,args.height,args.dpi)<=0: parser.error('screen dimensions and DPI must be positive')
    root,runtime=args.run_dir.resolve(),args.koreader.resolve()
    server=MockServer(0)
    if args.fetch and args.fetch_book: parser.error('choose one fetch mode')
    if args.annotations and not args.fetch_book: parser.error('--annotations requires --fetch-book')
    if (args.hash_storage or args.dir_storage) and not args.fetch_book: parser.error('metadata storage selection requires --fetch-book')
    if args.hash_storage and args.dir_storage: parser.error('choose one metadata storage location')
    if args.fetch_book:
        def book_source(uid,revision=None):
            return '<html><body><h1>Chapter '+str(uid)+'</h1>'+''.join(
                '<p>Original chapter '+str(uid)+' paragraph '+str(11 if args.annotations and int(uid)==3 and i==12 else i)+'. '
                + ('😀 &amp; <em>跨标签文字</em> ' if args.annotations and int(uid)==4 and i==8 else '')
                + ('Unique native translation refresh text. '*8)+'</p>'
                + ('' if int(uid)==6 else '<p class="wr-translation">第'+str(uid)+'章译文段落 '+str(i)+'。'+('原生双语正文验证。'*10)+'</p>')
                for i in range(1,13))+'</body></html>'
        server.chapter_source=book_source
    elif args.fetch:
        server.chapter_source=lambda uid,revision=None: '<html><body><h1>Chapter One</h1>'+''.join(
            '<p>Original paragraph '+str(i)+'. '+('Unique source text for native translation refresh. '*8)+'</p>'
            '<p class="wr-translation">译文段落 '+str(i)+'。'+('原生双语正文验证。'*10)+'</p>' for i in range(1,13))+'</body></html>'
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
        if args.annotations:env['WEREAD_TRANSLATION_ANNOTATIONS']='1'
        if args.hash_storage:env['WEREAD_TRANSLATION_HASH_STORAGE']='1'
        if args.dir_storage:env['WEREAD_TRANSLATION_DIR_STORAGE']='1'
        log=root/'evidence/runtime.log'
        try:
            with log.open('w') as out:
                probe='translation_fetch_book_smoke.lua' if args.fetch_book else 'translation_fetch_smoke.lua' if args.fetch else 'translation_reader_smoke.lua' if args.reader else 'translation_display_smoke.lua'
                result=subprocess.run(['./luajit',str(REPO/'spec/koreader'/probe)],
                    cwd=runtime,env=env,stdout=out,stderr=subprocess.STDOUT,timeout=120)
            if (args.fetch or args.fetch_book) and result.returncode==0:
                before=len(server.events)
                with (root/'evidence/offline.log').open('w') as out:
                    result=subprocess.run(['./luajit',str(REPO/'spec/koreader'/probe)],cwd=runtime,
                        env=env|dict(WEREAD_TRANSLATION_FETCH_OFFLINE='1'),stdout=out,stderr=subprocess.STDOUT,timeout=120)
                assert len(server.events)==before,'fresh offline process attempted HTTP'
        finally:
            server.shutdown();thread.join()
        if result.returncode==0:
            assert b'forceRePaint failed' not in log.read_bytes(),'native repaint failed'
            if not (args.fetch or args.fetch_book):assert not server.events,'display core attempted network requests'
            else:
                for event in server.events:
                    path=event['path']
                    assert (event['method']=='GET' and path.startswith('/web/reader/')) or (event['method']=='POST' and (path=='/web/book/chapterInfos' or path in ('/web/book/chapter/e_0','/web/book/chapter/e_1','/web/book/chapter/e_2','/web/book/chapter/e_3'))), 'translation fetch attempted an account mutation'
        print(('PASS' if result.returncode==0 else 'FAIL')+': '+str(log))
        raise SystemExit(result.returncode)
    finally: server.server_close()


if __name__=='__main__': main()
