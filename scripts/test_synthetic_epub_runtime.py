#!/usr/bin/env python3
"""Render the deterministic upload EPUB in two isolated KOReader screen sizes."""
import argparse,os,subprocess,sys,tempfile
from pathlib import Path
from synthetic_upload_epub import build,build_reading

REPO=Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    choice=parser.add_mutually_exclusive_group();choice.add_argument('--reading',action='store_true');choice.add_argument('--fixture-format',choices=('mobi','azw3'));args=parser.parse_args()
    runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file():parser.error('Linux KOReader runtime required')
    if not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    with tempfile.TemporaryDirectory(prefix='weread-epub-fixture-',dir='/dev/shm') as temporary:
        root=Path(temporary);extension=args.fixture_format or 'epub';book=root/('fixture.'+extension)
        if args.fixture_format:
            from synthetic_format_trial import build as build_format
            body=build_format(extension)
        else:body=build_reading() if args.reading else build()
        book.write_bytes(body)
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            profile=root/('profile'+str(width));profile.mkdir();xdg=root/('xdg'+str(width));xdg.mkdir(mode=0o700)
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),SDL_VIDEODRIVER='dummy',
                EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi))
            result=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/synthetic_upload_epub_render.lua'),str(book),'2' if args.reading or args.fixture_format else '1'],
                cwd=runtime,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60)
            if result.returncode:raise RuntimeError('synthetic EPUB render failed: '+result.stdout[-2000:])
            print(f'PASS: synthetic {extension.upper()} native render {width}x{height}')


if __name__=='__main__':main()
