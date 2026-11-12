"""Loopback initialization hypotheses, with independent existing DTO checks."""
from copy import deepcopy
from urllib.parse import urlsplit
from native_reader_fixture import NativeReaderServer,BOOK_ID

MODES=('accepted','noack','delayed','rejected','changed_counts')
class NativeInitialServer(NativeReaderServer):
    def __init__(self,mode='accepted'):
        if mode not in MODES:raise ValueError('initial_position/mock_mode')
        super().__init__();self.mode=mode;self.delayed=None;self.delay_reads=0
        self.progress[BOOK_ID]=dict(chapterUid=0,chapterOffset=0,progress=0,readingTime=0,recordReadingTime=0,ttsTime=0)
    def get_progress(self,book):
        if self.delayed is not None:
            if self.delay_reads:self.delay_reads-=1
            else:self.progress[BOOK_ID]=self.delayed;self.delayed=None
        return super().get_progress(book)
    def route(self,method,target,data):
        url=urlsplit(target)
        writing=method=='POST' and url.hostname=='i.weread.qq.com' and url.path=='/book/read'
        if writing and self.native_posts:raise ValueError('initial_position/mock_replay')
        old=deepcopy(self.progress[BOOK_ID]) if writing else None
        result=super().route(method,target,data)
        if writing:
            for k in ('readingTime','recordReadingTime','ttsTime'):self.progress[BOOK_ID][k]=old[k]
            if self.mode=='changed_counts':self.progress[BOOK_ID]['readingTime']=1
            if self.mode=='delayed':self.delayed=deepcopy(self.progress[BOOK_ID]);self.progress[BOOK_ID]=old;self.delay_reads=2
            if self.mode=='noack':return 200,{}
            if self.mode=='rejected':self.progress[BOOK_ID]=old;return 200,dict(succ=0)
        return result
