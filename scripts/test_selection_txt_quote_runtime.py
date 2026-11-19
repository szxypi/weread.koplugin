#!/usr/bin/env python3
"""Compare synthetic TXT UTF-16 ranges with KOReader Lua; no account access."""
import argparse
import json
import re
import subprocess


def row(prefix,quote,suffix='',*,bom=False):
    raw=('\ufeff' if bom else '')+prefix+quote+suffix
    before=('\ufeff' if bom else '')+prefix
    first=len(before.encode('utf-16-le'))//2
    last=first+len(quote.encode('utf-16-le'))//2
    start=len(prefix.encode('utf-16-le'))//2;end=start+len(quote.encode('utf-16-le'))//2
    return dict(raw=raw,first=first,last=last,text=quote.replace('\r\n','\n'),
                range=f'{start}-{end}',quote=quote)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container',default='weread-validation');parser.add_argument('--runtime',default='/validation/runtime/lib/koreader')
    parser.add_argument('--source',default='/source');args=parser.parse_args(argv)
    if (not re.fullmatch('[A-Za-z0-9_.-]{1,128}',args.container)
            or any(not value.startswith('/') or '\x00' in value for value in (args.runtime,args.source))):
        parser.error('invalid isolated runtime')
    values=[row('Prefix 😀.\n','A unique synthetic passage for testing a plain text highlight.','\n'),
            row('Prefix 😀.\n','A unique synthetic passage for testing a plain text highlight.','\n',bom=True),
            row('前文\r\n','A unique 😀 selected passage with combining e\u0301.','\n'),
            row('Before 😀\n','Unique literal &amp; <tag> stays.','\n'),
            row('Before\n','Unique first line\r\n  second line.','\n')]
    invalid=dict(values[2]);invalid.update(first=invalid['first']+10_000,invalid=True);values.append(invalid)
    payload=json.dumps(values,ensure_ascii=False,separators=(',',':')).encode()
    command=['docker','exec','-i','-w',args.runtime,args.container,'./luajit',
             args.source+'/spec/koreader/selection_txt_quote_probe.lua',args.source]
    result=subprocess.run(command,input=payload,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=45)
    marker=b'\nWEREAD_TXT_QUOTE='
    if result.returncode or result.stdout.count(marker)!=1:raise ValueError('txt_quote/runtime')
    value=json.loads(result.stdout.split(marker,1)[1].splitlines()[0])
    if value!=dict(result='PASS',accepted=5,rejected=1):raise ValueError('txt_quote/result')
    print(json.dumps(value));return 0


if __name__=='__main__':raise SystemExit(main())
