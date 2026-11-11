"""Rebuild a pending bookmark plan without persisting source or quotations."""
from copy import deepcopy
from annotation_experiment_model import digest,marks_state
from bookmark_point import point_range,from_mark
from bookmark_trial_model import bind,request
from fetch_weread_epub import decode_content_shards
from selection_trial_probe import SelectionProbe
from verify_annotation_experiment import AnnotationProbe
from verify_bookmark_trial import BookmarkProbe


def isolate_added(current,selection):
    marks=current
    if len(marks['updated'])!=selection['mark_count']+1:raise ValueError('bookmark_recovery/count')
    matches={}
    for key,row in marks['updated'].items():
        if row.get('type')!=0 or str(row.get('chapterUid'))!=selection['chapter_uid']:continue
        try:point_range(row.get('range'))
        except ValueError:continue
        for remove_chapter in (False,True):
            original=dict(updated={k:deepcopy(v) for k,v in marks['updated'].items() if k!=key},
                chapters={k:deepcopy(v) for k,v in marks['chapters'].items() if not remove_chapter or k!=selection['chapter_uid']})
            if digest(original)==selection['marks_sha256']:matches[key]=(dict(id=key,sha256=digest(row)),original)
    if len(matches)!=1:raise ValueError('bookmark_recovery/ambiguous')
    return next(iter(matches.values()))


class BaselineNotes(AnnotationProbe):
    def __init__(self,selection,opener=None):
        super().__init__(opener);self.selection=selection;self.target=None

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        value=super().request(stage,url,body,credentials,timeout)
        if body is None and '/book/bookmarklist?' in url:
            current=marks_state(value,self.selection['book_id'],self.selection['owner'])
            target,original=isolate_added(current,self.selection)
            if self.target is not None and target!=self.target:raise ValueError('bookmark_recovery/changed')
            self.target=target;filtered=deepcopy(value)
            filtered['updated']=[row for row in value['updated'] if row['bookmarkId']!=target['id']]
            filtered['chapters']=[row for row in value.get('chapters',[]) if str(row['chapterUid']) in original['chapters']]
            return filtered
        return value


def rebuild(saved,credentials,store,expected,source=None):
    state,receipt=store.read()
    if (store.native or state is None or state['phase'] not in ('create_pending','created') or digest(state['plan'])!=expected
            or state['plan']['selection']['owner']!=saved['vid'] or credentials['vid']!=saved['vid']):raise ValueError('bookmark_recovery/intent')
    selection=state['plan']['selection'];notes=BaselineNotes(selection)
    source=source or SelectionProbe(notes=notes)
    if source.notes is not notes:notes=source.notes
    plan=source.prepare(saved,credentials,existing=selection)
    raw=decode_content_shards(*(source.web.shards[k] for k in ('e_0','e_1','e_3')))
    first=source.payload['selection_preview']['first'];body=request(plan.context,raw,first)
    if bind(plan.bound,body)!=state['plan'] or not notes.target:raise ValueError('bookmark_recovery/plan')
    target=notes.target
    if state['target'] is not None and state['target']!=target:raise ValueError('bookmark_recovery/target')
    # Subsequent observations must include the complete new record, not the
    # filtered original-set projection used solely to reconstruct the old plan.
    full=AnnotationProbe();full.identity=selection['book_id'];full.grant=digest(credentials)
    full.report['stages']=notes.report['stages'];source.notes=full
    probe=BookmarkProbe(source,store);probe.raw=raw;probe.first=first;probe.bound=state['plan'];probe.body=body
    probe.target=target;probe.receipt=receipt;probe.posts=1
    found,observed=probe.read(credentials)
    row=observed['marks']['updated'][found['id']]
    point=from_mark(raw,body['bookId'],str(body['chapterUid']),row)
    if found!=target or point['chapter_offset']!=first or store.read()[1]!=receipt:raise ValueError('bookmark_recovery/changed')
    return probe,dict(result='PASS',account_data_posts=0,exact_original_plan_rebuilt=True,unique_new_bookmark_verified=True,
        original_record_hashes_match=True,source_point_roundtrip=True,bookmark_text_returned=bool(row.get('markText')),
        preview_crlf_count=row.get('markText','').count('\r\n'),intent_state=state['phase'])


def resume_delete(probe,credentials,on_final=None):
    probe.current();state,receipt=probe.store.read()
    if receipt!=probe.receipt or state['plan']!=probe.bound or state['phase'] not in ('create_pending','created'):raise ValueError('bookmark_recovery/replaced')
    if state['phase']=='create_pending':probe.receipt=probe.store.advance(receipt,'created',target=probe.target)
    probe.read(credentials);probe.receipt=probe.store.advance(probe.receipt,'delete_pending')
    probe.post(credentials,'delete_pending','/book/removeBookmark',dict(bookmarkIds=[probe.target['id']]))
    _target,final=probe.read(credentials,deleted=True)
    from verify_owner_reading import reading_position
    from verify_web_source_progress import BASE
    source=probe.source;source.web.verify_account()
    after=reading_position(source.web.request('progress_after',BASE+'/web/book/getProgress?bookId='+source.plan.bound['book_id']),source.plan.bound['book_id'])
    if after!=source.plan.web_position:raise ValueError('bookmark_recovery/web_position')
    if on_final:on_final()
    probe.receipt=probe.store.advance(probe.receipt,'verified');probe.store.finish(probe.receipt)
    if probe.store.read()!=(None,None):raise ValueError('bookmark_recovery/cleanup')
    return dict(result='PASS',account_data_posts=1,cumulative_trial_data_posts=2,create_replayed=False,independent_original_plan_rebuilt=True,
        test_bookmark_absent=True,original_records_restored=True,web_position_unchanged=True,
        derived_chapter_metadata_changed=final['marks']['chapters']!=source.plan.baseline['marks']['chapters'],intent_state='absent')


def reconcile_deleted(saved,credentials,store,expected,source=None):
    """An ambiguous deletion can only be checked; it cannot consume a new slot."""
    state,receipt=store.read()
    if (store.native or state is None or state['phase'] not in ('delete_pending','verified') or digest(state['plan'])!=expected
            or state['plan']['selection']['owner']!=saved['vid'] or credentials['vid']!=saved['vid']):raise ValueError('bookmark_recovery/intent')
    selection=state['plan']['selection'];source=source or SelectionProbe()
    plan=source.prepare(saved,credentials,existing=selection)
    raw=decode_content_shards(*(source.web.shards[k] for k in ('e_0','e_1','e_3')))
    first=source.payload['selection_preview']['first'];body=request(plan.context,raw,first)
    if bind(plan.bound,body)!=state['plan'] or state['target']['id'] in plan.baseline['marks']['updated']:raise ValueError('bookmark_recovery/plan')
    probe=BookmarkProbe(source,store);probe.raw=raw;probe.first=first;probe.bound=state['plan'];probe.body=body
    probe.target=state['target'];probe.receipt=receipt;probe.posts=2
    probe.read(credentials,deleted=True)
    return probe


def finish_reconcile(probe,credentials,on_final=None):
    from verify_owner_reading import reading_position
    from verify_web_source_progress import BASE
    state,receipt=probe.store.read();probe.current()
    if state is None or state['phase'] not in ('delete_pending','verified') or receipt!=probe.receipt or state['plan']!=probe.bound:
        raise ValueError('bookmark_recovery/replaced')
    probe.read(credentials,deleted=True);source=probe.source;source.web.verify_account()
    after=reading_position(source.web.request('progress_after',BASE+'/web/book/getProgress?bookId='+probe.body['bookId']),probe.body['bookId'])
    if after!=source.plan.web_position:raise ValueError('bookmark_recovery/web_position')
    if on_final:on_final()
    if state['phase']=='delete_pending':probe.receipt=probe.store.advance(receipt,'verified')
    probe.store.finish(probe.receipt)
    if probe.store.read()!=(None,None):raise ValueError('bookmark_recovery/cleanup')
    return dict(result='PASS',account_data_posts=0,create_replayed=False,delete_replayed=False,
        independent_original_plan_rebuilt=True,test_bookmark_absent=True,original_records_restored=True,web_position_unchanged=True,intent_state='absent')
