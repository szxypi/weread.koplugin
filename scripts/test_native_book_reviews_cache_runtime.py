#!/usr/bin/env python3
"""Packaged KOReader review cache, separate online/offline/failure processes."""
import argparse
import atexit
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--run-dir',type=Path)
    parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--thought',action='store_true')
    parser.add_argument('--public-stdin',action='store_true')
    args=parser.parse_args()
    raw=sys.stdin.buffer.read(16385) if args.public_stdin else b''
    if args.public_stdin:
        if len(raw)>16384 or set(json.loads(raw))!={'url','sha256'} or args.thought:raise ValueError('input_scope')
        temporary=tempfile.TemporaryDirectory(prefix='review-image-',dir='/dev/shm');atexit.register(temporary.cleanup)
        root=Path(temporary.name)/'run'
    else:
        if not args.run_dir:parser.error('--run-dir required without --public-stdin')
        root=args.run_dir.resolve()
    root.mkdir(parents=True,exist_ok=False)
    repo=Path(__file__).resolve().parent.parent;runtime=args.koreader.resolve()
    profile=root/'profile';plugins=profile/'plugins';plugins.mkdir(parents=True)
    xdg=root/'xdg';xdg.mkdir(mode=0o700)
    candidate=root/'candidate.zip'
    subprocess.run(['bash',str(repo/'scripts/package_release.sh'),str(candidate)],check=True,capture_output=True)
    with zipfile.ZipFile(candidate) as archive:
        for entry in archive.infolist():
            if entry.is_dir():continue
            path=Path(entry.filename)
            assert not path.is_absolute() and '..' not in path.parts and path.parts[0]=='weread.koplugin'
            target=plugins/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(archive.read(entry))
            assert target.read_bytes()==archive.read(entry)
    probe=repo/('spec/koreader/thought_replies_cache_ui_probe.lua' if args.thought
                else 'spec/koreader/native_book_reviews_cache_ui_probe.lua')
    env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),EMULATE_READER='1',EMULATE_BW_SCREEN='1',
        EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),
        EMULATE_READER_DPI=str(args.dpi))
    if args.public_stdin:env['WEREAD_PUBLIC_REVIEW_IMAGE']='1'
    marker=b'\nWEREAD_REVIEW_CACHE_UI='
    for mode,requests in (('online',2),('offline',0),('failure',1)):
        result=subprocess.run([str(runtime/'luajit'),str(probe)],cwd=runtime,env=dict(env,WEREAD_REVIEW_CACHE_MODE=mode),
                              input=raw,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
        (root/(mode+'.log')).write_bytes(result.stdout)
        assert result.returncode==0 and result.stdout.count(marker)==1,mode
        report=json.loads(result.stdout.split(marker,1)[1].splitlines()[0])
        assert report==dict(result='PASS',mode=mode,items=40,requests=0 if args.thought else requests,
                            reply_requests=requests),mode
    print('PASS: packaged native reviews, saved offline and failure fallback')


if __name__=='__main__':main()
