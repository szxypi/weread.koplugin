#!/usr/bin/env python3
"""Reproduce buffered fclose errors with synthetic files in a Linux KOReader runtime.

Default offline. --koreader runs six temporary-file checks, using Linux
RLIMIT_FSIZE and no accounts or network. Optional --baseline also measures
an old book_store.lua and expects the original checkpoint-corruption bug.
Only fixed labels, error codes and booleans leave the temporary directory.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

code=r'''require('setupkoenv');package.path=assert(os.getenv('WEREAD_IO_REPO'))..'/?.lua;'..package.path
local json=require('json');local Store=dofile(assert(os.getenv('WEREAD_IO_MODULE')))
local root=assert(os.getenv('WEREAD_IO_ROOT'));local kind=assert(os.getenv('WEREAD_IO_CASE'))
local target=(kind=='save-metadata' or kind=='clear-downloads') and 'metadata.json'
 or kind=='save-articles' and 'articles.json' or 'reading_state.json'
local failed_write,failed_close,close_errno
local real_open=io.open
rawset(io,'open',function(path,mode)
 local file,err=real_open(path,mode)
 if path~=root..'/'..target..'.tmp' or mode~='wb' or not file then return file,err end
 return {write=function(_self,raw) local ok,e=file:write(raw);failed_write=not ok;return ok,e end,
  close=function() local ok,e,n=file:close();failed_close=not ok;close_errno=n;return ok,e,n end}
end)
local settings={cache_dir=root};local index={cache_dir=root};local ok
if kind=='dispatch' then
 settings.get=function(_self,key,default) if key=='account' then return {user_vid='900000'} end;return default end
 settings.get_book=function() return Store.load(settings,'900001',index) end
 settings.patch_reading_state=function(_self,id,patch) return Store.patch_reading(settings,id,index,patch) end
 local Journal=require('weread.lib.source_dispatch'):new{settings=settings,nonce=function() return string.rep('a',32) end}
 local point={book_id='900001',chapter_uid='2',chapter_offset=5,basis='filtered_xhtml_utf16',upload_verified=false,
 file_id=string.rep('b',64),raw_sha256=string.rep('c',64),book_version=1,render_path='OEBPS/text/chapter.xhtml'}
 local receipt=Journal:begin('900001',{book_id='900001',chapter_uid='2',chapter_idx=1,chapter_offset=5,percent=37},point,'position')
 ok=receipt~=nil
elseif kind=='patch' then ok=Store.patch_reading(settings,'900001',index,{summary=string.rep('x',1024)})
elseif kind=='clear-downloads' then ok=Store.clear_downloads(settings,'900001',index)
else
 local book={book_id='900001',cache_dir=root,title='Fixture'}
 if kind=='save-metadata' then book.title=string.rep('x',1024)
 elseif kind=='save-reading' then book.summary=string.rep('x',1024)
 elseif kind=='save-articles' then book.mp_articles={{title=string.rep('x',1024)}} end
 ok=Store.save(settings,'900001',book)
end
rawset(io,'open',real_open)
print('\nWEREAD_IO_RESULT='..json.encode{reported_success=ok,buffered_write_succeeded=not failed_write,close_failed=failed_close,close_errno=close_errno})
'''

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path)
    parser.add_argument('--baseline',type=Path)
    args=parser.parse_args(argv)
    if not args.koreader:
        if args.baseline:parser.error('--baseline requires --koreader')
        print(json.dumps(dict(result='OFFLINE_ONLY',real_account_requests=0,keychain_accesses=0)))
        return 0
    if sys.platform!='linux':parser.error('kernel fault injection requires Linux')
    import resource
    runtime=args.koreader.resolve();repo=Path(__file__).resolve().parent.parent
    if not (runtime/'luajit').is_file() or not (runtime/'reader.lua').is_file():parser.error('invalid KOReader runtime')
    variants=[]
    if args.baseline:
        baseline=args.baseline.resolve()
        if not baseline.is_file():parser.error('missing baseline module')
        variants.append(('baseline',baseline))
    variants.append(('fixed',repo/'weread/lib/book_store.lua'))
    reports=[]
    for variant,module in variants:
        for kind in ('patch','dispatch','save-metadata','save-reading','save-articles','clear-downloads'):
            with tempfile.TemporaryDirectory(prefix='weread-book-io-') as name:
                work=Path(name)
                target=('metadata.json' if kind in ('save-metadata','clear-downloads')
                        else 'articles.json' if kind=='save-articles' else 'reading_state.json')
                records={
                    'metadata.json':dict(book_id='900001',title='x'*1024 if kind=='clear-downloads' else 'Fixture',
                                         cached_file=str(work/'missing.epub')),
                    'reading_state.json':dict(progress=37,pending_upload_position=dict(
                        book_id='900001',chapter_uid='2',chapter_offset=5,percent=37)),
                    'articles.json':dict(mp_articles=[dict(title='Old fixture')]),
                }
                for file,value in records.items():(work/file).write_text(json.dumps(value))
                before=(work/target).read_bytes()

                def limit():
                    signal.signal(signal.SIGXFSZ,signal.SIG_IGN)
                    resource.setrlimit(resource.RLIMIT_FSIZE,(256,256))

                result=subprocess.run(['./luajit','-e',code],cwd=runtime,env=dict(
                    os.environ,WEREAD_IO_ROOT=name,WEREAD_IO_MODULE=str(module),
                    WEREAD_IO_CASE=kind,WEREAD_IO_REPO=str(repo)),
                    preexec_fn=limit,capture_output=True,text=True,timeout=20)
                assert result.returncode==0,(kind,result.stderr[-500:])
                data=json.loads(result.stdout.split('WEREAD_IO_RESULT=',1)[1])
                data.update(variant=variant,case=kind,prior_bytes_preserved=(work/target).read_bytes()==before,
                            temporary_absent=not (work/(target+'.tmp')).exists())
                assert data['buffered_write_succeeded'] and data['close_failed'] and data['close_errno']==27,data
                if variant=='fixed':
                    assert not data['reported_success'] and data['prior_bytes_preserved'] and data['temporary_absent'],data
                else:
                    assert not data['prior_bytes_preserved'],data
                reports.append(data)
    print(json.dumps(dict(result='PASS',synthetic_only=True,cases=reports,real_account_requests=0,keychain_accesses=0),indent=2))
    return 0


if __name__=='__main__':raise SystemExit(main())
