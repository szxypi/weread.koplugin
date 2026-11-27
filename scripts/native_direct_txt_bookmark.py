"""Independent source and cloud checks for a native TXT bookmark round trip."""
from hashlib import sha256
import time
from urllib.parse import urlencode

from annotation_experiment_model import digest
from bookmark_trial_model import bind_txt,observe,txt_request
from highlight_trial_model import PendingObservation
from selection_trial_probe import Plan
from verify_annotation_experiment import AnnotationProbe
from verify_cloud_source_target import WebSourceProbe
from verify_eink_login import BASE
from verify_native_chapter_package import ChapterProbe
from verify_native_direct_roundtrip import Reads,catalog,check,current_source,state,txt_sample
from verify_owner_reading import reading_position
from verify_web_source_progress import BASE as WEB
from shelf_flag_change_contract import state_hash


class TxtBookmarkProbe:
    def __init__(self):
        # The duplex broker calls the same read-only interface for EPUB and TXT.
        self.source=self
        self.web=WebSourceProbe()
        self.notes=AnnotationProbe()
        self.target=None

    def prepare(self,saved,credentials,offset):
        if hasattr(self,'plan') or saved['vid']!=credentials['vid']:
            raise ValueError('direct_txt_bookmark/owner')
        self.sample=txt_sample(ChapterProbe(),credentials,offset)
        model=self.sample['expected']
        if model['format']!='txt' or model['version']!=0:
            raise ValueError('direct_txt_bookmark/format')
        book=self.sample['book_id']
        self.native=Reads(credentials,book)
        self.progress,self.counts=state(self.native.request('progress',BASE+'/book/getProgress?'+urlencode(dict(bookId=book)),
            credentials=credentials),book,'native')
        uid=self.progress['chapter_uid']
        index=self.progress['chapter_idx']
        chapters=[chapter for chapter in model['chapters'] if str(chapter['uid'])==uid and chapter['free_or_owned']]
        if len(chapters)!=1:
            raise ValueError('direct_txt_bookmark/chapter')
        self.web.vid=saved['vid']
        for key,value in saved['cookies'].items():
            self.web.set_cookie(key,value)
        self.web.verify_account()
        self.web.book_id,self.web.chapter=book,uid
        raw=current_source(self.sample,uid,credentials,self.web)
        source_hash=sha256(raw).hexdigest()
        self.body=txt_request(book,uid,raw.decode())
        self.native_source=dict(book_id=book,uid=uid,book_version=0,source_sha256=source_hash,
            plain_text=True,chapter_idx=index,source_bytes=len(raw))
        self.notes.identity,self.notes.grant=book,digest(credentials)
        before=self.notes.observe(credentials,'txt_bookmark_baseline')
        if book not in before['shelf'] or any(row.get('type')==0 and str(row.get('chapterUid'))==uid
                and row.get('range')==self.body['range'] for row in before['marks']['updated'].values()):
            raise ValueError('direct_txt_bookmark/existing')
        self.shelf=state_hash(self.native.request('shelf',BASE+'/shelf/sync',credentials=credentials))
        self.web_shelf=state_hash(self.web.request('shelf',WEB+'/web/shelf/sync'))
        web_position=reading_position(self.web.request('progress_after',WEB+'/web/book/getProgress?bookId='+book),book)
        bound=bind_txt(dict(owner=saved['vid'],book_id=book,chapter_uid=uid,chapter_idx=index,source_sha256=source_hash,
            catalog_sha256=catalog(self.web,book,uid,index),baseline_sha256=digest(before),
            web_position_sha256=digest(web_position),grant_sha256=self.notes.grant),self.body)
        self.plan=Plan(bound,self.body.copy(),before,model['chapters'],web_position)
        self.payload=dict(cookies=saved['cookies'],source_raw_sha256=source_hash)
        self.baseline(credentials,'txt_bookmark_independent')
        return self.native_source

    def current(self):
        bound=self.plan.bound
        if (bind_txt(bound,self.body)!=bound or digest(self.plan.baseline)!=bound['baseline_sha256']
                or digest(self.plan.web_position)!=bound['web_position_sha256']
                or self.payload['source_raw_sha256']!=bound['source_sha256']):
            raise ValueError('direct_txt_bookmark/plan_changed')

    def recheck_source(self,credentials):
        self.current()
        bound=self.plan.bound
        book,uid,index=(bound[key] for key in ('book_id','chapter_uid','chapter_idx'))
        raw=current_source(self.sample,uid,credentials,self.web)
        if (sha256(raw).hexdigest()!=bound['source_sha256'] or txt_request(book,uid,raw.decode())!=self.body
                or catalog(self.web,book,uid,index)!=bound['catalog_sha256']):
            raise ValueError('direct_txt_bookmark/source_changed')

    def observe(self,credentials,stage):
        self.current()
        result=self.notes.observe(credentials,stage)
        check(self.web,self.native,credentials,self.plan.bound['book_id'],self.progress,self.counts,
            self.shelf,self.web_shelf,both_counts=True)
        return result

    def baseline(self,credentials,stage):
        observed=self.observe(credentials,stage)
        if observed!=self.plan.baseline:
            raise ValueError('direct_txt_bookmark/baseline_changed')
        return observed

    def read(self,credentials,*,deleted=False):
        for attempt in range(3):
            if attempt:time.sleep(.5*attempt)
            observed=self.observe(credentials,'txt_bookmark_readback')
            try:
                target=observe(self.plan.baseline,observed,self.body,deleted=deleted,target=self.target)
            except PendingObservation:
                if attempt==2:raise
            else:
                return target,observed
