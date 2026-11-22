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
        elif target.hostname=='i.weread.qq.com' and target.path=='/shelf/sync' and self.command=='GET' and server.mode.startswith('preview'):
            data=json.dumps(dict(books=[dict(bookId='42',finishReading=0,secret=0)],archive=[])).encode()
        elif target.hostname=='i.weread.qq.com' and target.path=='/book/getProgress' and self.command=='GET':
            server.valid &= parse_qs(target.query)=={'bookId':['42']}
            if server.mode=='cloud_move':time.sleep(0.8)
            count=sum(path=='/book/getProgress' for _,_,path in server.calls)
            uid,index,offset,progress,summary=37,1,CLOUD_OFFSET,50,'Synthetic cloud point'
            if server.mode=='cloud_changed' and count==2:offset+=1
            if server.mode=='cloud_after' and count>=3:offset+=1
            if server.mode=='cloud_other' or server.mode.startswith('cross_'):uid,index,offset=38,2,CROSS_OFFSET
            if server.mode=='cross_changed' and count>=3:offset+=1
            if server.mode=='cross_after_switch' and count>=9:offset+=1
            if server.mode=='cross_unlocatable':offset=0
            if server.mode=='cloud_empty':uid,index,offset,progress,summary=0,0,0,0,''
            if server.mode=='preview_changed' and count==2:offset+=1
            if server.mode=='preview_missing':summary=None
            data=json.dumps(dict(bookId='42',chapterUid=uid,chapterIdx=index,chapterOffset=offset,progress=progress,
                summary=summary,readingTime=100,recordReadingTime=0,ttsTime=0)).encode()
        elif target.hostname=='i.weread.qq.com' and target.path=='/book/chapterInfos' and self.command=='POST':
            request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            server.valid &= request==dict(bookIds=['42'],synckeys=[0],updateTimes=[0],maxfreeIdx=[0])
            data=json.dumps(dict(data=[dict(bookId='42',updated=[dict(chapterUid=37,chapterIdx=1,title='Synthetic chapter',wordCount=500,price=0),
                dict(chapterUid=38,chapterIdx=2,title='Next synthetic chapter',wordCount=500,price=1 if server.mode=='cross_denied' else 0)])])).encode()
        elif target.hostname=='i.weread.qq.com' and target.path=='/book/chapterdownload' and self.command=='GET':
            query=parse_qs(target.query,keep_blank_values=True)
            chapters=query.get('chapters',[''])[0];server.valid &= query.get('bookId')==['42'] and chapters in ('0,37','0,38') and query.get('stopAutoPayWhenBNE')==['1']
            uid=chapters.split(',')[-1];data=archive([('text/'+uid+'.html',BODY if uid=='37' else BODY2),('style/book.css','p{color:black}')]);headers['encryptkey']='vwSvXMONEDngLYTAXw3olg=='
        elif target.hostname=='weread.qq.com' and target.path=='/api/userInfo' and self.command=='GET':
            server.valid &= parse_qs(target.query)=={'userVid':['12345678']}
            headers['Set-Cookie']='wr_skey'+'=synthetic-refreshed-cookie; Path=/; Secure'
            data=json.dumps(dict(vid='12345678')).encode()
        elif target.hostname=='weread.qq.com' and target.path=='/web/book/getProgress' and self.command=='GET' and server.mode.startswith('preview'):
            count=sum(path=='/web/book/getProgress' for _,_,path in server.calls)
            offset=CLOUD_OFFSET+(1 if server.mode=='preview_web_changed' and count==2 else 0)
            data=json.dumps(dict(bookId='42',chapterUid=37,chapterIdx=1,chapterOffset=offset,progress=50)).encode()
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
            if server.mode=='move' and target.path.endswith('e_0'):time.sleep(0.8)
            raw=BODY2 if request.get('c')==weread_e('38') else BODY
            if server.mode=='mismatch':raw=raw.replace('Unique paragraph 0001','Changed paragraph 0001')
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
       'cross_cached','cross_download','cross_changed','cross_after_switch','cross_denied','cross_unlocatable')

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
                        payload['path']=path;server.mode=mode;server.calls=[]
                        child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_position_reader_probe.lua')],
                            input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=150)
                        result=frame(child,'WEREAD_POSITION_READER=');assert result['ok'] and result['mode']==mode
                        if mode in ('match','preview'):compare_offset(result)
                        assert server.valid and not server.leaked
                        assert all(path not in ('/web/book/read','/book/read') for _,_,path in server.calls)
                        if mode not in ('move','cloud_move') and not mode.startswith(('cross_','preview')):
                            assert sum(path=='/web/book/chapter/e_0' for _,_,path in server.calls)==(2 if mode in ('cloud','cloud_after') else 1)
                        if mode.startswith('cloud') and mode!='cloud_move':
                            assert sum(path=='/book/getProgress' for _,_,path in server.calls)==(4 if mode in ('cloud','cloud_after') else 2)
                        if mode=='preview':
                            assert sum(path=='/book/getProgress' for _,_,path in server.calls)==2
                            assert sum(path=='/web/book/getProgress' for _,_,path in server.calls)==2
        print('PASS: installed native reader source proof and cloud navigation at both sizes')
    finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--mode',choices=MODES,action='append')
    args=parser.parse_args();run(args.koreader.resolve(),args.mode or MODES)
