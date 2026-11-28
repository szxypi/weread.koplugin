"""Opt-in local TXT reader fixture; native writes never reach a real service."""
from copy import deepcopy
import time
from urllib.parse import urlsplit,parse_qs
from mock_weread import MockServer,BOOK_ID,CHAPTERS,chapter_txt
from native_txt_read_model import body
from txt_coordinates import PlainSource
from verify_native_position_lua import equivalent

GRANT=dict(vid='900000',accessToken='synthetic-native-access',refreshToken='synthetic-native-refresh',
           deviceId='eink334691225'+'1'*19)
GUEST='5ecdcfd7f'
COUNTS=dict(readingTime=10,recordReadingTime=20,ttsTime=0)


class NativeReaderServer(MockServer):
    def __init__(self,port=0,log_path=None):
        super().__init__(port,log_path);self.content_format='txt';self.native_posts=0;self.native_mode='plain'
        self.progress[BOOK_ID]=dict(chapterUid=2,chapterIdx=2,chapterOffset=120,progress=37,
                                   summary=PlainSource(chapter_txt(2)).excerpt(120)['text'],**COUNTS)

    def route(self,method,target,data):
        url=urlsplit(target);query=parse_qs(url.query)
        if url.hostname=='weread.qq.com' and url.path=='/mock/native-control' and method=='POST':
            if set(data)!={'mode'} or data['mode'] not in ('plain','noack'):raise ValueError('native_reader/control')
            self.native_mode=data['mode'];return 200,dict(ok=True)
        if url.hostname=='i.weread.qq.com':
            if url.path=='/book/getProgress' and method=='GET':
                if query!={'bookId':[BOOK_ID]}:raise ValueError('native_reader/book')
                return 200,self.get_progress(BOOK_ID)
            if url.path=='/book/info' and method=='GET' and query=={'bookId':[BOOK_ID]}:
                status,result=super().route(method,target,data);result['version']=0;return status,result
            if url.path=='/feature' and method=='GET':
                if query!={'synckey':['0']}:raise ValueError('native_reader/feature')
                return 200,dict(feature=dict(guest_token=GUEST))
            if url.path=='/book/read' and method=='POST':
                if query or self.native_posts>=3:raise ValueError('native_reader/write_limit')
                for key,maximum in (('chapterOffset',2147483647),('currentProgress',100),('random',999),('timestamp',4102444800)):
                    if type(data.get(key)) is not int or not 0<=data[key]<=maximum:raise ValueError('native_reader/point')
                uid=data.get('chapterUid')
                if (data.get('bookId')!=BOOK_ID or type(uid) is not int or uid not in (1,2,3)
                        or data.get('chapterIdx')!=next(c['chapterIdx'] for c in CHAPTERS if c['chapterUid']==uid)
                        or not 0<=time.time()-data['timestamp']<=30):raise ValueError('native_reader/scope')
                excerpt=PlainSource(chapter_txt(uid)).excerpt(data['chapterOffset'])
                p=dict(book_id=BOOK_ID,chapter_uid=str(uid),chapter_idx=data['chapterIdx'],chapter_offset=data['chapterOffset'],
                       raw_percent=data['currentProgress'],summary=excerpt['text'])
                expected=body(GRANT,p,0,GUEST,data['timestamp'],data['random'],data.get('recordCreateTimeZone'))
                if not equivalent(expected,data):raise ValueError('native_reader/body')
                with self.lock:
                    self.native_posts+=1
                    self.progress[BOOK_ID]=dict(chapterUid=uid,chapterIdx=p['chapter_idx'],chapterOffset=p['chapter_offset'],
                                               progress=p['raw_percent'],summary=p['summary'],**COUNTS)
                return 200,{} if self.native_mode=='noack' else dict(succ=1)
            if method=='POST':raise ValueError('native_reader/unexpected_native_write')
        if url.hostname=='weread.qq.com' and url.path=='/web/book/read':raise ValueError('native_reader/web_write_forbidden')
        return super().route(method,target,data)

    def preserved_counts(self):
        return {key:self.get_progress(BOOK_ID)['book'][key] for key in COUNTS}==COUNTS

    def snapshot(self):return deepcopy(self.get_progress(BOOK_ID))
