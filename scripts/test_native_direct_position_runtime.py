#!/usr/bin/env python3
"""Actual KOReader native viewport, source equality and read-only position proof."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit
from fetch_weread_epub import weread_e
from mock_weread import shards
from run_persistent_ui_probe import extract_candidate
from test_native_chapter_package import archive
from verify_source_coordinates import FilteredSource

REPO=Path(__file__).resolve().parent.parent
BODY='<html><body>'+''.join(f'<p>Unique paragraph {i:04d}: native position example 中文😀 with exact source content.</p>'
                          for i in range(1,151))+'</body></html>'
BODY2=BODY.replace('Unique paragraph','Target paragraph')
MODEL=FilteredSource(BODY)
CLOUD_OFFSET=MODEL.starts[''.join(MODEL.characters).index('Unique paragraph 0100')]
MODEL2=FilteredSource(BODY2)
CROSS_OFFSET=MODEL2.starts[''.join(MODEL2.characters).index('Target paragraph 0100')]

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*_args):pass
    def do_GET(self):self.dispatch()
    def do_POST(self):self.dispatch()
    def dispatch(self):
        server=self.server
        server.leaked |= any(k.lower() in ('vid','accesstoken','cookie') for k in self.headers)
        target=urlsplit(parse_qs(urlsplit(self.path).query).get('url',[''])[0])
        server.calls.append((self.command,target.hostname,target.path))
        code,headers,data=200,{},None
        if target.hostname=='i.weread.qq.com' and target.path=='/book/info' and self.command=='GET':
            data=json.dumps(dict(bookId='42',format='epub',version=1)).encode()
        elif target.hostname=='i.weread.qq.com' and target.path=='/book/bookmarklist' and self.command=='GET' and server.mode.startswith('selection_direct_'):
            server.valid &= parse_qs(target.query)=={'bookId':['42'],'synckey':['0']}
            data=json.dumps(dict(bookId='42',updated=[server.mark] if server.mark else [],
                chapters=[dict(chapterUid=37,title='Synthetic chapter')],hasMore=0)).encode()
        elif target.hostname=='i.weread.qq.com' and target.path=='/review/list' and self.command=='GET' and server.mode.startswith('selection_direct_'):
            server.valid &= parse_qs(target.query)=={'bookId':['42'],'listType':['11'],'listMode':['0'],'mine':['1'],'synckey':['0'],'count':['20']}
            data=json.dumps(dict(reviews=[dict(review=server.review)] if server.review else [],totalCount=int(server.review is not None),hasMore=0)).encode()
        elif target.hostname=='i.weread.qq.com' and target.path in ('/book/addBookmark','/review/add') and self.command=='POST' and server.mode.startswith('selection_direct_'):
            request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            is_bookmark=server.mode.startswith('selection_direct_bookmark')
            if is_bookmark:
                from bookmark_point import from_mark,project
                point=from_mark(BODY,'42','37',dict(type=0,chapterUid=37,range=request.get('range'),markText=request.get('markText')))
                quote=project(BODY,point['chapter_offset'])['markText']
            else:
                from annotation_source_quotes import SourceQuotes
                quote=SourceQuotes(BODY,body_only=True).quote(request.get('range'))
                server.valid &= quote=='Unique paragraph 0001'
            server.valid &= request.get('bookId')=='42' and request.get('bookVersion')==1
            if target.path=='/book/addBookmark':
                server.valid &= request.get('chapterUid')==37 and request.get('markText')==quote and request.get('type')==(0 if is_bookmark else 1) and server.mark is None
                if not server.mode.endswith('_no_effect'):
                    server.mark=dict(bookmarkId='synthetic-direct-mark',chapterUid=37,type=request['type'],range=request['range'],markText=quote,
                        style=request['style'],createTime=1700000000)
                    if not is_bookmark:server.mark['colorStyle']=request['colorStyle']
            else:
                server.valid &= request.get('chapterUid')=='37' and request.get('abstract')==quote and request.get('isPrivate')==1 and server.review is None
                if not server.mode.endswith('_no_effect'):
                    server.review=dict(reviewId='synthetic-direct-thought',bookId='42',userVid='12345678',chapterUid=37,type=1,
                        range=request['range'],abstract=quote,content=request['content'],isPrivate=1,createTime=1700000000)
            data=json.dumps({} if server.mode.endswith(('_lost_ack','_no_effect')) else dict(succ=1)).encode()
        elif target.hostname=='i.weread.qq.com' and target.path=='/book/removeBookmark' and self.command=='POST' and server.mode=='selection_direct_bookmark_roundtrip':
            request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            server.valid &= request=={'bookmarkIds':['synthetic-direct-mark']} and server.mark is not None and server.mark['type']==0
            server.mark=None;data=json.dumps(dict(succ=1)).encode()
        elif target.hostname=='i.weread.qq.com' and target.path=='/shelf/sync' and self.command=='GET' and server.mode.startswith(('preview','upload','interval')):
            data=json.dumps(dict(books=[dict(bookId='42',finishReading=0,secret=0)],archive=[])).encode()
        elif target.hostname=='i.weread.qq.com' and target.path=='/feature' and self.command=='GET' and server.mode.startswith(('upload','interval')):
            server.valid &= parse_qs(target.query)=={'synckey':['0']}
            data=json.dumps(dict(feature={})).encode()
        elif target.hostname=='i.weread.qq.com' and target.path=='/book/read' and self.command=='POST' and server.mode.startswith(('upload','interval')):
            request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            server.valid &= (request.get('bookId')=='42' and request.get('chapterUid')==37 and request.get('chapterIdx')==1
                and type(request.get('chapterOffset')) is int and bool(request.get('summary')) and request.get('readingTime')==0)
            server.cloud_offset=request['chapterOffset'];server.cloud_summary=request['summary']
            posts=sum(path=='/book/read' for _,_,path in server.calls)
            data=json.dumps({} if server.mode in ('upload_lost_ack','upload_initial_noack') or server.mode in ('interval_noack','interval_close_noack') and posts==2 else dict(succ=1)).encode()
        elif target.hostname=='i.weread.qq.com' and target.path=='/book/getProgress' and self.command=='GET':
            server.valid &= parse_qs(target.query)=={'bookId':['42']}
            if server.mode=='cloud_move':time.sleep(0.8)
            count=sum(path=='/book/getProgress' for _,_,path in server.calls)
            uid,index,offset,progress,summary=37,1,CLOUD_OFFSET,50,'Synthetic cloud point'
            if server.mode.startswith(('upload','interval')):
                offset,summary=server.cloud_offset,server.cloud_summary
                if server.mode=='upload_changed' and count>=3:offset+=1
                if server.mode in ('interval_conflict','interval_close_conflict'):
                    post_index=next((i for i,(_,_,path) in enumerate(server.calls) if path=='/book/read'),len(server.calls))
                    if sum(path=='/book/getProgress' for _,_,path in server.calls[post_index+1:])>=2:offset+=1
            if server.mode=='cloud_changed' and count==2:offset+=1
            if server.mode=='cloud_after' and count>=3:offset+=1
            if server.mode=='cloud_other' or server.mode.startswith('cross_'):uid,index,offset=38,2,CROSS_OFFSET
            if server.mode=='cross_changed' and count>=3:offset+=1
            if server.mode=='cross_after_switch' and count>=9:offset+=1
            if server.mode=='cross_unlocatable':offset=0
            if server.mode=='cloud_empty':uid,index,offset,progress,summary=0,0,0,0,''
            if server.mode=='preview_changed' and count==2:offset+=1
            if server.mode.startswith('upload_initial'):
                if not any(path=='/book/read' for _,_,path in server.calls):uid,index,offset,summary=0,0,0,''
                progress=0
            response=dict(bookId='42',chapterUid=uid,chapterIdx=index,chapterOffset=offset,progress=progress,
                summary=summary,readingTime=100,recordReadingTime=0,ttsTime=0)
            if server.mode.startswith('upload_initial'):
                response['readingTime']=3 if server.mode=='upload_initial_changed' and any(path=='/book/read' for _,_,path in server.calls) else 2
                if server.mode=='upload_initial_recorded':response['recordReadingTime']=1
                if server.mode=='upload_initial_tts':response['ttsTime']=1
            if server.mode=='preview_missing' or server.mode=='upload_missing_before' and not any(path=='/book/read' for _,_,path in server.calls) \
                or server.mode=='upload_missing_after' and any(path=='/book/read' for _,_,path in server.calls):response.pop('summary')
            data=json.dumps(response).encode()
        elif target.hostname=='i.weread.qq.com' and target.path=='/book/chapterInfos' and self.command=='POST':
            request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            server.valid &= request==dict(bookIds=['42'],synckeys=[0],updateTimes=[0],maxfreeIdx=[0])
            data=json.dumps(dict(data=[dict(bookId='42',updated=[dict(chapterUid=37,chapterIdx=1,title='Synthetic chapter',wordCount=500,price=0),
                dict(chapterUid=38,chapterIdx=2,title='Next synthetic chapter',wordCount=500,price=1 if server.mode=='cross_denied' else 0)])])).encode()
        elif target.hostname=='i.weread.qq.com' and target.path=='/book/chapterdownload' and self.command=='GET':
            query=parse_qs(target.query,keep_blank_values=True)
            chapters=query.get('chapters',[''])[0];server.valid &= query.get('bookId')==['42'] and chapters in ('0,37','0,38') and query.get('stopAutoPayWhenBNE')==['1']
            uid=chapters.split(',')[-1];raw=BODY if uid=='37' else BODY2
            if server.mode in ('selection_direct_mark_changed','selection_direct_thought_changed','selection_direct_bookmark_changed') and sum(path=='/book/chapterdownload' for _,_,path in server.calls)>=3:
                raw=raw.replace('Unique paragraph 0001','Changed paragraph 0001')
            if server.mode in ('selection_direct_auth_expired','selection_direct_limited'):
                code,data=(401 if server.mode=='selection_direct_auth_expired' else 429),b''
            else:
                data=archive([('text/'+uid+'.html',raw),('style/book.css','p{color:black}')]);headers['encryptkey']='vwSvXMONEDngLYTAXw3olg=='
        elif target.hostname=='weread.qq.com' and target.path=='/api/userInfo' and self.command=='GET':
            server.valid &= parse_qs(target.query)=={'userVid':['12345678']}
            if server.mode=='selection_direct_web_expired':code,data=401,b''
            else:
                headers['Set-Cookie']='wr_skey'+'=synthetic-refreshed-cookie; Path=/; Secure'
                data=json.dumps(dict(vid='12345678')).encode()
        elif target.hostname=='weread.qq.com' and target.path=='/web/book/getProgress' and self.command=='GET' and server.mode.startswith(('preview','upload','interval')):
            count=sum(path=='/web/book/getProgress' for _,_,path in server.calls)
            offset=(server.cloud_offset if server.mode.startswith(('upload','interval')) else CLOUD_OFFSET)+(1 if server.mode=='preview_web_changed' and count==2 else 0)
            response=dict(bookId='42',chapterUid=37,chapterIdx=1,chapterOffset=offset,progress=50,
                summary=server.cloud_summary if server.mode.startswith(('upload','interval')) else 'Synthetic cloud point')
            if server.mode.startswith('upload_initial'):
                response['progress']=0
                if not any(path=='/book/read' for _,_,path in server.calls):
                    response.update(chapterUid=0,chapterIdx=0,chapterOffset=0,summary='')
            if server.mode in ('preview_missing','upload_missing_before'):response.pop('summary')
            data=json.dumps(response).encode()
        elif target.hostname=='weread.qq.com' and target.path=='/web/book/chapterInfos' and self.command=='POST':
            request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            server.valid &= request==dict(bookIds=['42'])
            data=json.dumps(dict(data=[dict(bookId='42',updated=[dict(chapterUid=37,chapterIdx=1),dict(chapterUid=38,chapterIdx=2)])])).encode()
        elif target.hostname=='weread.qq.com' and target.path.startswith('/web/reader/') and self.command=='GET':
            state={'reader':{'bookInfo':{'bookId':'42','title':'Synthetic','author':'Fixture'},'psvts':'mock-session',
                             'pclts':'mock-clock','progress':{},'currentChapter':{}}}
            data=('<script>window.__INITIAL_STATE__='+json.dumps(state)+';(function(){})();</script>').encode()
        elif target.hostname=='weread.qq.com' and target.path in ('/web/book/chapter/e_0','/web/book/chapter/e_1','/web/book/chapter/e_3') and self.command=='POST':
            request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            server.valid &= request.get('b')==weread_e('42') and request.get('c') in (weread_e('37'),weread_e('38'))
            if server.mode in ('move','selection_direct_move') and target.path.endswith('e_0'):time.sleep(0.8)
            if server.mode=='interval_move' and target.path.endswith('e_0') and any(path=='/book/read' for _,_,path in server.calls):time.sleep(0.8)
            raw=BODY2 if request.get('c')==weread_e('38') else BODY
            if server.mode in ('mismatch','selection_direct_mismatch'):raw=raw.replace('Unique paragraph 0001','Changed paragraph 0001')
            data=shards(raw)[['e_0','e_1','e_3'].index(target.path.rsplit('/',1)[1])].encode()
        else:code,data=400,b''
        self.send_response(code)
        for key,value in headers.items():self.send_header(key,value)
        self.send_header('Content-Length',str(len(data)));self.end_headers()
        try:self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError):pass  # The reader cancelled an in-flight read.

def frame(child,marker):
    if child.returncode:raise AssertionError(child.stdout[-7000:]+child.stderr[-7000:])
    values=[line for line in child.stdout.splitlines() if line.startswith(marker)]
    assert len(values)==1
    return json.loads(values[0][len(marker):])

def compare_offset(result):
    model=FilteredSource(BODY)
    flat,indices=[],[]
    for index,char in enumerate(model.characters):
        if not char.isspace():flat.append(char);indices.append(index)
    text=result['text'];haystack=''.join(flat);start=haystack.find(text)
    assert start>=0 and haystack.find(text,start+1)<0
    point=start+result['point_offset']
    assert point<len(indices) and model.starts[indices[point]]==result['offset']

MODES=('match','mismatch','move','cloud','cloud_cancel','cloud_move','cloud_changed','cloud_after','cloud_other','cloud_empty',
       'preview','preview_changed','preview_web_changed','preview_missing',
       'upload','upload_cancel','upload_changed','upload_lost_ack','upload_missing_before','upload_missing_after',
       'upload_initial_time','upload_initial_noack','upload_initial_changed','upload_initial_recorded','upload_initial_tts',
       'cross_cached','cross_download','cross_changed','cross_after_switch','cross_denied','cross_unlocatable',
       'interval','interval_conflict','interval_noack','interval_move','interval_offline',
       'interval_close','interval_close_conflict','interval_close_noack','interval_close_offline','interval_close_reopen',
       'selection_direct','selection_direct_mismatch','selection_direct_move','selection_direct_mark','selection_direct_thought',
       'selection_direct_mark_changed','selection_direct_thought_changed','selection_direct_thought_draft',
       'selection_direct_bookmark','selection_direct_bookmark_quick','selection_direct_bookmark_changed','selection_direct_bookmark_no_effect','selection_direct_bookmark_roundtrip',
       'selection_direct_auth_expired','selection_direct_web_expired','selection_direct_limited',
       'selection_direct_mark_lost_ack','selection_direct_thought_lost_ack','selection_direct_mark_no_effect','selection_direct_thought_no_effect')

def run(runtime,modes=MODES):
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-position-package-',dir='/dev/shm') as package:
            candidate=Path(package)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                for mode in modes:
                    with tempfile.TemporaryDirectory(prefix='weread-position-ui-',dir='/dev/shm') as root:
                        xdg=Path(root)/'xdg';xdg.mkdir(mode=0o700)
                        (Path(root)/'settings').mkdir();(Path(root)/'plugins').mkdir();extract_candidate(candidate,Path(root)/'plugins')
                        env=dict(os.environ,KO_HOME=root,XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                            SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                            EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi),WEREAD_SYNTHETIC='1')
                        creds=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId='eink334691225'+'0'*19)
                        payload=dict(credentials=creds,mock_endpoint='http://127.0.0.1:'+str(server.server_port),mode=mode)
                        server.mode='cross_denied' if mode=='cross_denied' else 'match';server.calls=[];server.leaked=False;server.valid=True
                        child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_position_prepare.lua'),str(REPO)],
                            input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=120)
                        prepared=frame(child,'WEREAD_POSITION_PREPARED=');path=prepared['path'];assert Path(path).is_file()
                        payload['second']=prepared.get('second')
                        payload['path']=path;server.mode=mode;server.calls=[];server.cloud_offset=CLOUD_OFFSET;server.cloud_summary='Synthetic cloud point'
                        server.mark=None;server.review=None
                        child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_position_reader_probe.lua')],
                            input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=150)
                        result=frame(child,'WEREAD_POSITION_READER=');assert result['ok'] and result['mode']==mode
                        if mode=='selection_direct':
                            from annotation_source_quotes import SourceQuotes
                            assert SourceQuotes(BODY,body_only=True).quote(result['range'])==result['quote']=='Unique paragraph 0001'
                        if mode in ('match','preview','preview_missing','upload','upload_missing_before','upload_initial_time','interval'):compare_offset(result)
                        assert server.valid and not server.leaked
                        writes=[path for _,_,path in server.calls if path in ('/web/book/read','/book/read')]
                        write_count=2 if mode in ('interval','interval_noack','interval_close','interval_close_noack') else 1 if mode.startswith('interval') or mode in ('upload','upload_lost_ack','upload_missing_before','upload_missing_after','upload_initial_time','upload_initial_noack','upload_initial_changed') else 0
                        assert writes==['/book/read']*write_count, (mode,writes)
                        mark_posts=sum(path=='/book/addBookmark' for _,_,path in server.calls)
                        thought_posts=sum(path=='/review/add' for _,_,path in server.calls)
                        assert mark_posts==(1 if mode in ('selection_direct_mark','selection_direct_mark_lost_ack','selection_direct_mark_no_effect',
                            'selection_direct_bookmark','selection_direct_bookmark_quick','selection_direct_bookmark_no_effect','selection_direct_bookmark_roundtrip') else 0), (mode,mark_posts)
                        assert thought_posts==(1 if mode in ('selection_direct_thought','selection_direct_thought_lost_ack','selection_direct_thought_no_effect') else 0), (mode,thought_posts)
                        assert sum(path=='/book/removeBookmark' for _,_,path in server.calls)==(1 if mode=='selection_direct_bookmark_roundtrip' else 0)
                        if mode=='selection_direct_bookmark_roundtrip':assert server.mark is None
                        if mode not in ('move','cloud_move') and not mode.startswith(('cross_','preview','upload','interval','selection_direct')):
                            assert sum(path=='/web/book/chapter/e_0' for _,_,path in server.calls)==(2 if mode in ('cloud','cloud_after') else 1)
                        if mode.startswith('cloud') and mode!='cloud_move':
                            assert sum(path=='/book/getProgress' for _,_,path in server.calls)==(4 if mode in ('cloud','cloud_after') else 2)
                        if mode=='preview':
                            assert sum(path=='/book/getProgress' for _,_,path in server.calls)==2
                            assert sum(path=='/web/book/getProgress' for _,_,path in server.calls)==2
        print('PASS: installed native reader selected scenarios at both sizes')
    finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--mode',choices=MODES,action='append')
    args=parser.parse_args();run(args.koreader.resolve(),args.mode or MODES)
