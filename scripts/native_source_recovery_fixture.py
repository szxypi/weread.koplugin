"""Opt-in loopback expiry cases; independent native refresh DTO validation."""
import hashlib
import time
from urllib.parse import urlsplit
from native_reader_fixture import NativeReaderServer,GRANT,BOOK_ID,chapter_txt
from txt_coordinates import PlainSource

MODES=('snapshot','prewrite','feature','second','post','unknown','foreign','cancel','save','save-sync','changed',
       'close-snapshot','close-prewrite','timer-snapshot','timer-prewrite','offline','account','suspend')


class NativeRecoveryServer(NativeReaderServer):
    def __init__(self):
        super().__init__();self.recovery_mode=None;self.auth_posts=0;self.info_reads=0;self.expiries=0
    def route(self,method,target,data):
        url=urlsplit(target)
        if url.hostname=='weread.qq.com' and url.path=='/mock/native-recovery' and method=='POST':
            if set(data)!={'mode'} or data['mode'] not in MODES or self.recovery_mode is not None:raise ValueError('recovery/control')
            self.recovery_mode=data['mode'];return 200,dict(ok=True)
        mode=self.recovery_mode
        if url.hostname=='i.weread.qq.com' and mode:
            if url.path=='/book/info' and method=='GET':
                self.info_reads+=1
                at=2 if mode in ('prewrite','close-prewrite','timer-prewrite') else 1
                expired=(mode not in ('feature','post') and self.expiries==0 and self.info_reads==at
                         or mode=='second' and self.auth_posts and self.expiries==1)
                if expired:self.expiries+=1;return 401,dict(errcode=-1)
            if url.path=='/feature' and method=='GET' and mode=='feature' and self.expiries==0:
                self.expiries+=1;return 401,dict(errcode=-1)
            if url.path=='/login' and method=='POST':
                self.auth_posts+=1
                if self.auth_posts>1:raise ValueError('recovery/replayed_auth')
                fields={'deviceId','deviceName','deviceType','timestamp','random','trackId','refreshToken','inBackground','kickType','refCgi','signature'}
                if (set(data)!=fields or data['deviceId']!=GRANT['deviceId'] or data['refreshToken']!=GRANT['refreshToken']
                        or data['deviceName']!='BOOX' or type(data['deviceType']) is not int or data['deviceType']!=3
                        or type(data['timestamp']) is not int or not 0<=time.time()*1000-data['timestamp']<=30000
                        or type(data['random']) is not int or not 1<=data['random']<=999
                        or data['trackId']!='' or data['inBackground']!=0 or data['kickType']!=1 or data['refCgi']!=''
                        or data['signature']!=hashlib.sha256(f"{data['timestamp']}{GRANT['deviceId']}{data['random']}".encode()).hexdigest()):raise ValueError('recovery/body')
                if mode=='unknown':return 200,{}
                if mode=='changed':
                    p=self.progress[BOOK_ID];p['chapterOffset']+=1;p['summary']=PlainSource(chapter_txt(p['chapterUid'])).excerpt(p['chapterOffset'])['text']
                return 200,dict(vid=900099 if mode=='foreign' else 900000,accessToken='synthetic-renewed-access')
            if url.path=='/book/read' and method=='POST' and mode=='post':
                super().route(method,target,data);self.expiries+=1;return 401,dict(errcode=-1)
        return super().route(method,target,data)
