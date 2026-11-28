"""Loopback-only shared server for native UI and independent Python readback."""
from copy import deepcopy
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json
import socket
import threading
from urllib.parse import parse_qs,urlsplit,urlencode
from urllib.request import Request,ProxyHandler,build_opener

from test_annotation_experiment import shelf,notebooks,position,marks,info,note,thoughts


class Server:
    def __init__(self,case='normal'):
        if case not in ('normal','lost-ack','public','changed-original','host-mismatch'):raise ValueError('synthetic case')
        self.case=case;self.new=None;self.original=thoughts()['reviews'][0];self.posts=[];self.gets=0;self.denied=0
        self.lock=threading.RLock();owner=self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*_args):pass
            def do_GET(self):self.answer('GET')
            def do_POST(self):self.answer('POST')
            def answer(self,method):
                try:
                    target=urlsplit(self.path);query=parse_qs(target.query)
                    if target.path!='/__proxy' or set(query)!={'url'}:raise ValueError('route')
                    original=urlsplit(query['url'][0]);path=original.path
                    if original.scheme!='https' or original.netloc!='i.weread.qq.com':raise ValueError('route')
                    length=int(self.headers.get('Content-Length','0'))
                    if not 0<=length<=16384:raise ValueError('limit')
                    raw=self.rfile.read(length);body=json.loads(raw) if raw else None
                    with owner.lock:value=owner.route(method,path,parse_qs(original.query),body,self.headers.get('X-Synthetic-Host')=='1')
                    if method=='POST' and owner.case=='lost-ack':
                        self.connection.shutdown(socket.SHUT_RDWR);self.connection.close();return
                    payload=json.dumps(value).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload)
                except Exception:
                    owner.denied+=1
                    try:self.send_error(400)
                    except OSError:pass
        self.http=ThreadingHTTPServer(('127.0.0.1',0),Handler);self.port=self.http.server_address[1]
        self.thread=threading.Thread(target=self.http.serve_forever,daemon=True)

    def __enter__(self):self.thread.start();return self
    def __exit__(self,*_args):self.http.shutdown();self.http.server_close();self.thread.join()

    def route(self,method,path,query,body,host=False):
        if method=='GET':
            if body is not None:raise ValueError('GET body')
            self.gets+=1
            if path=='/shelf/sync' and not query:return shelf()
            if path=='/user/notebooks' and query=={'count':['100']}:return notebooks()
            if path=='/review/list' and query==dict(bookId=['41'],listType=['11'],listMode=['0'],mine=['1'],synckey=['0'],count=['20']):
                value=thoughts(self.new);value['reviews'][0]=deepcopy(self.original)
                if host and self.case=='host-mismatch' and self.new is not None:value['reviews'][0]['review']['content']='Concurrent edit'
                return value
            if path=='/book/bookmarklist' and query==dict(bookId=['41'],synckey=['0']):return marks()
            if path=='/book/info' and query==dict(bookId=['41']):return info()
            if path=='/book/getProgress' and query==dict(bookId=['41']):return position()
            raise ValueError('GET scope')
        if method!='POST' or query or len(self.posts)>=3 or not isinstance(body,dict):raise ValueError('POST scope')
        expected=['/review/add','/review/useredit','/review/delete'][len(self.posts)]
        if path!=expected:raise ValueError('POST order')
        if not self.posts:
            if (set(body)!={'bookId','chapterUid','chapterIdx','bookVersion','type','range','abstract','isPrivate','content'}
                    or body['bookId']!='41' or body['chapterUid']!='2' or body['bookVersion']!=77 or body['isPrivate']!=1
                    or not body['content'].startswith('KOReader 私密想法验证 ')):raise ValueError('create scope')
            self.new=note('synthetic-created',body['content'],0 if self.case=='public' else 1)
            self.new['review']['chapterUid']='2'
            if self.case=='changed-original':self.original['review']['content']='Concurrent edit'
            result=dict(reviewId='synthetic-created')
        else:
            if not self.new or body.get('reviewId')!='synthetic-created':raise ValueError('existing target')
            if len(self.posts)==1:
                if set(body)!={'reviewId','content'} or body['content']!=self.posts[0]['body']['content'].replace('初始内容','修改后'):raise ValueError('edit scope')
                self.new['review']['content']=body['content']
            else:
                if set(body)!={'reviewId'}:raise ValueError('delete scope')
                self.new=None
            result=dict(succ=1)
        self.posts.append(dict(path=path,body=deepcopy(body)));return result


class Opener:
    def __init__(self,port):self.port=port;self.opener=build_opener(ProxyHandler({}))
    def open(self,request,timeout):
        if request.get_method()!='GET' or request.get_header('Vid')!='900000' or request.get_header('Accesstoken')!='synthetic-native-access':raise ValueError('synthetic host request')
        url='http://127.0.0.1:'+str(self.port)+'/__proxy?'+urlencode(dict(url=request.full_url))
        return self.opener.open(Request(url,headers={'X-Synthetic-Host':'1'}),timeout=timeout)
