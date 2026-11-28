"""Bind a new unstarted-book experiment to two completed, immutable trials."""
import hashlib
from pathlib import Path
import tempfile
from native_direct_time_trial_store import Intent
from native_time_capture_evidence import account_key
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from verify_eink_login import BASE as NATIVE
from verify_native_chapter_package import ChapterProbe
from verify_native_discovery import identity


def inspect_book(grant,book):
    probe=ChapterProbe();shelf=probe.request('shelf',NATIVE+'/shelf/sync',credentials=grant)
    rows=shelf.get('books') if isinstance(shelf,dict) else None
    if not isinstance(rows,list) or len(rows)>5000:raise ValueError('unstarted_ui/shelf')
    ids=[]
    for row in rows:
        value=identity(row.get('bookId')) if isinstance(row,dict) else None
        if value and value not in ids:ids.append(value)
    if book not in ids or ids.index(book)>50:raise ValueError('unstarted_ui/shelf')
    sample,chapter,source=probe.inspect(grant,ids.index(book))
    if sample['book_id']!=book:raise ValueError('unstarted_ui/source')
    return sample,chapter,source


class OrdinaryUnstartedUiTimeStore(Intent):
    service='org.codex.weread.ordinary-unstarted-ui-time-v1'
    def __init__(self,backend=None):
        path=Path(tempfile.gettempdir())/('codex-ordinary-unstarted-ui-time-'+ACCOUNT+'.lock')
        super().__init__(backend=backend if backend is not None else MacKeychain(service=self.service,account=ACCOUNT),
            lock=(lambda:project_lock(path)) if backend is None else None)
    def pending(self):
        value,_=self.read();return value is not None and value['phase']!='verified'


class OrdinaryUnstartedUiPositionStore(OrdinaryUnstartedUiTimeStore):
    service='org.codex.weread.ordinary-unstarted-ui-position-v1'
    def __init__(self,backend=None):
        path=Path(tempfile.gettempdir())/('codex-ordinary-unstarted-ui-position-'+ACCOUNT+'.lock')
        Intent.__init__(self,backend=backend if backend is not None else MacKeychain(service=self.service,account=ACCOUNT),
            lock=(lambda:project_lock(path)) if backend is None else None)


class NativeDirectUnstartedTimeStore(OrdinaryUnstartedUiTimeStore):
    service='org.codex.weread.native-direct-unstarted-time-v1'
    def __init__(self,backend=None):
        path=Path(tempfile.gettempdir())/('codex-native-direct-unstarted-time-'+ACCOUNT+'.lock')
        Intent.__init__(self,backend=backend if backend is not None else MacKeychain(service=self.service,account=ACCOUNT),
            lock=(lambda:project_lock(path)) if backend is None else None)


class PreviousSamples:
    def __init__(self,time_store,position_store):
        self.time_store=time_store;self.position_store=position_store
        self.time,self.time_raw=time_store.read();self.position,self.position_raw=position_store.read()
        if (not self.time or not self.position or self.time.get('phase')!='verified'
                or self.position.get('phase')!='verified' or not isinstance(self.time_raw,bytes)
                or not isinstance(self.position_raw,bytes)):
            raise ValueError('unstarted_ui/prior')

    def check(self,grant,selected,interval=None):
        if self.time_store.read()!=(self.time,self.time_raw) or self.position_store.read()!=(self.position,self.position_raw):
            raise ValueError('unstarted_ui/prior_changed')
        try:
            old=self.time['plan'];position=self.position['plan'];source=old['record']['source']
            book=source['book_id'];body=old['body']['books']
            if (old['record']['owner']!=account_key(grant['vid']) or old['selection']['duration']!=2
                    or len(body)!=1 or body[0]['bookId']!=book or body[0]['readingTime']!=2
                    or position['record']['prior_attempt']!=self.time['attempt']
                    or position['record']['prior_receipt_sha256']!=hashlib.sha256(self.time_raw).hexdigest()
                    or position['record']['version']!=source['version']
                    or position['selection']['target']['book_id']!=book
                    or selected['book_id']==book):raise ValueError('unstarted_ui/prior')
            if interval is not None:
                rows=interval['protocol_rows']
                if (not isinstance(rows,list) or len(rows)!=1 or type(rows[0]['start_time']) is not int
                        or rows[0]['duration']!=2 or type(self.position['claimed_at']) is not int
                        or rows[0]['start_time']<max(old['selection']['start_time']+2,self.position['claimed_at'])):
                    raise ValueError('unstarted_ui/interval')
        except (KeyError,TypeError,IndexError):raise ValueError('unstarted_ui/prior') from None
        return True
