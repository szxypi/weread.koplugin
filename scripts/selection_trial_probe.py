"""Read-only preparation and independent observation; optional exact new-mark cleanup."""
from dataclasses import dataclass
import secrets
import time
from annotation_experiment_model import digest,note_text,shelf_state
from fetch_weread_epub import decode_content_shards
from owner_selection_preview import choose,validate_input
from selection_trial_model import bind,fingerprint,observe,restored,validate_plan,PendingObservation
from source_upload_candidate import chapter_index
from verify_annotation_experiment import AnnotationProbe
from verify_eink_login import BASE as NATIVE,NativeProbe,ProbeError
from verify_owner_selection_preview import Preflight
from verify_owner_reading import reading_position,validate_cookies
from verify_web_source_progress import BASE,identifier


def prepare_web_handoff(store,saved,source):
    """Verify and persist a rotated Web grant before passing it to native UI.

    Account/source plans stay bound; an unrelated saved-session replacement
    cannot be silently adopted. Nothing is reserved or dispatched here.
    """
    from secure_weread_session import COOKIE_NAMES
    from verify_translation_preflight import save_refreshed_web_session
    source.current();source.web.verify_account();owner=source.plan.bound['owner']
    current={cookie.name:cookie.value for cookie in source.web.cookies if cookie.name in COOKIE_NAMES
        and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
    validate_cookies(current,owner)
    changed=save_refreshed_web_session(store,saved,source.web);fresh=store.load()
    if (fresh['vid']!=owner or fresh['cookies']!=current or not changed and fresh!=saved):raise ValueError('selection_trial/session_changed')
    source.payload['cookies']=dict(current);source.current();return fresh


@dataclass(frozen=True,repr=False)
class Plan:
    bound:dict
    context:dict
    baseline:dict
    chapters:list
    web_position:dict


class Reading(Preflight):
    requested_book=None
    def select_shelf_book(self):
        if self.requested_book is None:return super().select_shelf_book()
        rows=self.request('shelf',BASE+'/web/shelf/sync').get('books')
        flags=shelf_state({'books':rows})
        if self.requested_book not in flags:raise ValueError('selection_trial/book_missing')
        self.book_id=identifier(self.requested_book);self.report['shelf_book_count']=len(rows)
        return self.book_id


class SelectionProbe:
    def __init__(self,web=None,notes=None,writer=None,sleep=time.sleep):
        self.web=web or Reading();self.notes=notes or AnnotationProbe();self.writer=writer or NativeProbe()
        self.sleep=sleep;self.plan=None;self.payload=None;self.original=None;self.created_id=None;self.mark=None;self.cleanup_posts=0
        self.derived_chapter_metadata_changed=False

    def prepare(self,saved,credentials,existing=None):
        if self.plan is not None:raise ValueError('selection_trial/consumed')
        if existing is not None:
            validate_plan(existing)
            if existing['owner']!=saved['vid']:raise ValueError('selection_trial/owner')
            self.web.requested_book=existing['book_id']
        if credentials['vid']!=saved['vid']:raise ValueError('selection_trial/owner')
        web=self.web;web.vid=saved['vid']
        for k,v in saved['cookies'].items():web.set_cookie(k,v)
        web.verify_account();payload=web.prepare();self.payload=payload
        self.notes.identity=payload['book_id'];self.notes.grant=digest(credentials)
        before=self.notes.observe(credentials,'selection_trial_baseline')
        metadata=self.notes.request('selection_trial_metadata',NATIVE+'/book/info?bookId='+payload['book_id'],credentials=credentials)
        if str(metadata.get('bookId'))!=payload['book_id']:raise ValueError('selection_trial/metadata')
        raw=decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3')))
        selected=choose(raw,before['marks']['updated'],payload['book_id'],payload['chapter_uid'],chapter_index(web.chapters,payload['chapter_uid']))
        nonce=existing['nonce'] if existing else secrets.token_hex(16);row=selected['reference']
        context=dict(bookId=payload['book_id'],chapterUid=payload['chapter_uid'],bookVersion=metadata.get('bookVersion',metadata.get('version')),
                     type=1,range=row['range'],abstract=row['markText'],isPrivate=1)
        if any(r['content'] in (note_text(nonce),note_text(nonce,True)) for r in before['thoughts'].values()):raise ValueError('selection_trial/existing_nonce')
        payload.update(vid=saved['vid'],cookies=saved['cookies'],selection_preview=dict(credentials=credentials,first=selected['first'],last=selected['last'],
            reference=row,body=dict(context,content=note_text(nonce))))
        validate_input(payload)
        bound=bind(saved['vid'],payload,context,before,web.chapters,web.baseline,nonce)
        if existing is not None and bound!=existing:raise ValueError('selection_trial/changed')
        if self.notes.observe(credentials,'selection_trial_independent')!=before:raise ValueError('selection_trial/changed')
        self.plan=Plan(bound,context,before,web.chapters,web.baseline);self.original=fingerprint(bound)
        return self.plan

    def current(self):
        p=self.plan
        if (p is None or fingerprint(p.bound)!=self.original
                or bind(p.bound['owner'],self.payload,p.context,p.baseline,p.chapters,p.web_position,p.bound['nonce'])!=p.bound
                or self.payload['selection_preview']['body']!=dict(p.context,content=note_text(p.bound['nonce']))):raise ValueError('selection_trial/changed')

    def baseline(self,credentials,stage):
        self.current();value=self.notes.observe(credentials,stage)
        if value!=self.plan.baseline:raise ValueError('selection_trial/changed')
        return value

    def read_step(self,credentials,step,target):
        self.current()
        for attempt in range(3):
            if attempt:self.sleep(.5*attempt)
            observed=self.notes.observe(credentials,'selection_trial_step_'+str(step))
            try:
                row,mark=observe(self.plan.baseline,observed,self.plan.context,self.plan.bound['nonce'],('created','edited','deleted')[step-1],self.created_id,self.mark)
                break
            except PendingObservation as pending:
                self.mark=pending.mark or self.mark
                if attempt==2:raise
        if step==1:
            if row['reviewId']!=target or target in self.plan.baseline['thoughts']:raise ValueError('selection_trial/target')
            self.created_id=target
        elif target!=self.created_id:raise ValueError('selection_trial/target')
        self.mark=mark or self.mark
        return mark

    def cleanup(self,credentials,store,receipt):
        self.current();state,owned=store.read()
        if (owned!=receipt or state['phase']!='pending' or state['native_steps']!=3 or state['plan']!=self.plan.bound
                or state['cleanup_pending'] or state['cleanup_verified'] or self.cleanup_posts):raise ValueError('selection_trial/intent')
        before=self.notes.observe(credentials,'selection_trial_before_cleanup')
        _row,mark=observe(self.plan.baseline,before,self.plan.context,self.plan.bound['nonce'],'deleted',self.created_id,self.mark)
        if mark is None:return store.verified_cleanup(receipt)
        if mark!=state['mark'] or self.cleanup_posts:raise ValueError('selection_trial/cleanup_target')
        receipt=store.claim_cleanup(receipt)
        # A single Python prototype POST, only to the independently identified
        # newly added mark. Unknown receipts never permit another dispatch.
        self.cleanup_posts=1
        try:self.writer.request('selection_trial_remove_new_mark',NATIVE+'/book/removeBookmark',dict(bookmarkIds=[mark['id']]),credentials)
        except ProbeError:pass
        for attempt in range(3):
            if attempt:self.sleep(.5*attempt)
            value=self.notes.observe(credentials,'selection_trial_cleanup_readback')
            observe(self.plan.baseline,value,self.plan.context,self.plan.bound['nonce'],'deleted',self.created_id,self.mark)
            if restored(self.plan.baseline,value,self.plan.context,self.plan.bound['nonce'],self.created_id,self.mark):return store.verified_cleanup(receipt)
        raise ValueError('selection_trial/cleanup_unconfirmed')

    def final(self,credentials,cookies):
        self.current();value=self.notes.observe(credentials,'selection_trial_final')
        if not restored(self.plan.baseline,value,self.plan.context,self.plan.bound['nonce'],self.created_id,self.mark):raise ValueError('selection_trial/final')
        self.derived_chapter_metadata_changed=value['marks']['chapters']!=self.plan.baseline['marks']['chapters']
        self.web.cookies.clear()
        for k,v in cookies.items():self.web.set_cookie(k,v)
        self.web.verify_account()
        after=reading_position(self.web.request('progress_after',BASE+'/web/book/getProgress?bookId='+self.plan.bound['book_id']),self.plan.bound['book_id'])
        if after!=self.plan.web_position:raise ValueError('selection_trial/position')
