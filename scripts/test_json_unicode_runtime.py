#!/usr/bin/env python3
"""KOReader decoder regression for escaped supplementary Unicode."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def run(runtime):
    repo=Path(__file__).resolve().parent.parent
    cases=[{'summary':'前😀后'}, {'😀':'𐀀􏿿'}, {'literal':r'\uD83D\uDE00'},
        {'mix':'quoted " and slash \\ then 😀 and 中文'}, {'items':['😀','𐀀',r'\\uD83D',None,17]},
        {'many':'😀'*600}]
    raw='\n'.join(json.dumps(value,ensure_ascii=True,separators=(',',':')) for value in cases)+'\n'
    env=dict(os.environ,WEREAD_SYNTHETIC='1',LD_LIBRARY_PATH=str(runtime/'libs'),SDL_VIDEODRIVER='dummy')
    result=subprocess.run([str(runtime/'luajit'),str(repo/'spec/koreader/json_unicode_probe.lua'),str(repo)],
        cwd=runtime,env=env,input=raw,text=True,capture_output=True,timeout=30)
    if result.returncode:raise AssertionError((result.stderr+result.stdout)[-2000:])
    prefix='WEREAD_JSON_UNICODE='
    values=[json.loads(line[len(prefix):]) for line in result.stdout.splitlines() if line.startswith(prefix)]
    if values!=cases:raise AssertionError('KOReader Unicode JSON round-trip mismatch')
    print('PASS: KOReader JSON preserves emoji, supplementary keys and literal escapes')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    args=parser.parse_args();run(args.koreader.resolve())
