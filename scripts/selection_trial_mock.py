"""Closed synthetic service for the source-selection trial, never production forwarding."""
from copy import deepcopy
import hashlib
import threading
from urllib.parse import urlencode,urlsplit
from urllib.request import ProxyHandler,Request,build_opener

from mock_weread import BOOK_ID,CHAPTERS,MockServer,shards
from my_cloud_marks_model import identifier
from verify_eink_login import NoRedirect
from verify_owner_reading import SourceText
from verify_source_coordinates import FilteredSource
from verify_web_source_progress import position


def credentials():return dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',deviceId='eink334691225'+'1'*19)


class Server(MockServer):
    def __init__(self,case='normal',log=None):
        super().__init__(0,log);self.case=case;self.selection_fixture=True;self.cleanup_posts=0;self.trial_denied=0
        self.posts=[];self.mark=None;self.chapter_added=False
        self.progress[BOOK_ID]=dict(chapterUid=2,chapterIdx=2,chapterOffset=120,progress=37,summary='合成进度')
        self.old_mark=dict(bookmarkId='synthetic-original-mark',chapterUid=2,type=1,range='1-2',markText='原有合成划线',style=1)
        self.original=deepcopy(self.selection_thoughts);self.thread=None
        if case=='lost-ack':self.control['selection_thought_mode']='empty'

    def __enter__(self):
        self.thread=threading.Thread(target=self.serve_forever,daemon=True);self.thread.start();return self

    def __exit__(self,*_args):self.shutdown();self.server_close();self.thread.join()

    def route(self,method,target,data):
        parsed=urlsplit(target);path=parsed.path
        if parsed.hostname=='i.weread.qq.com':
            if method=='GET' and path=='/book/bookmarklist':
                chapters=[] if self.case=='new-chapter-metadata' and not self.chapter_added else [dict(chapterUid=2,title=CHAPTERS[1]['title'])]
                rows=[deepcopy(self.old_mark)]+([deepcopy(self.mark)] if self.mark else [])
                return 200,dict(updated=rows,chapters=chapters,synckey=0)
            if method=='GET' and path=='/book/getProgress':return 200,self.get_progress(BOOK_ID)
            if method=='POST' and path=='/book/removeBookmark':
                if self.cleanup_posts or self.mark is None or data!={'bookmarkIds':[self.mark['bookmarkId']]} or self.mark['bookmarkId']=='synthetic-original-mark':
                    self.trial_denied+=1;raise ValueError('cleanup scope')
                self.cleanup_posts+=1;self.posts.append(path)
                if self.case!='cleanup-no-change':self.mark=None
                return 200,'' if self.case=='lost-ack' else dict(succ=1)
            if method=='POST' and path in ('/review/add','/review/useredit','/review/delete'):
                if len([p for p in self.posts if p.startswith('/review/')])>=3:self.trial_denied+=1;raise ValueError('native post bound')
                result=super().route(method,target,data);self.posts.append(path)
                if path=='/review/add':
                    if self.case in ('associated','auto-remove','lost-ack','mark-changed','cleanup-no-change','new-chapter-metadata'):
                        self.mark=dict(bookmarkId='synthetic-associated',chapterUid=2,type=1,range=data['range'],markText=data['abstract'],style=1)
                        self.chapter_added=True
                    elif self.case=='unrelated-mark':self.mark=dict(self.old_mark,bookmarkId='synthetic-unrelated',range='3-4')
                    if self.case=='public':
                        for key in self.selection_thoughts:
                            if key not in self.original:self.selection_thoughts[key]['isPrivate']=0
                    if self.case=='changed-original':self.selection_thoughts['synthetic-existing-thought']['content']='其他设备修改'
                elif path=='/review/useredit' and self.case=='mark-changed':self.mark['style']=2
                elif path=='/review/delete' and self.case=='auto-remove':self.mark=None
                return result
        return super().route(method,target,data)


class Opener:
    def __init__(self,server):self.server=server;self.opener=build_opener(ProxyHandler({}),NoRedirect())
    def open(self,request,timeout):
        body=request.data
        if request.get_header('Vid')!='900000' or request.get_header('Accesstoken')!='mock-native-access':raise ValueError('synthetic host credentials')
        if urlsplit(request.full_url).hostname!='i.weread.qq.com' or request.get_method() not in ('GET','POST'):raise ValueError('synthetic host origin')
        if body is not None and request.full_url!='https://i.weread.qq.com/book/removeBookmark':raise ValueError('synthetic host data route')
        url='http://127.0.0.1:'+str(self.server.server_port)+'/__proxy?'+urlencode(dict(url=request.full_url))
        return self.opener.open(Request(url,data=body,headers=dict(request.header_items()),method=request.get_method()),timeout=timeout)


class Web:
    def __init__(self,server):
        self.server=server;self.cookies={};self.vid='900000';self.book_id=BOOK_ID
        self.baseline=position(server.get_progress(BOOK_ID),BOOK_ID);self.chapters=deepcopy(CHAPTERS)
        encoded=shards(server.chapter_source(2));self.shards=dict(zip(('e_0','e_1','e_3'),encoded));self.report={'stages':[]}
    def set_cookie(self,key,value):self.cookies[key]=value
    def verify_account(self):pass
    def request(self,*_args,**_kwargs):return self.server.get_progress(BOOK_ID)
    def close(self):pass
    def prepare(self):
        raw=self.server.chapter_source(2);parser=SourceText();parser.feed(raw);text=parser.samples[0]
        books=self.server.route('GET','https://weread.qq.com/web/shelf/sync',{})[1]['books']
        return dict(book_id=BOOK_ID,chapter_uid='2',source_text=text,source_sample_offset=FilteredSource(raw).locate(text)[0],
            source_format='web_xhtml',source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest(),
            shelf_ids=[str(row['bookId']) for row in books if identifier(str(row['bookId']))],shelf_books=len(books))
