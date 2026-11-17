#!/usr/bin/env python3
"""Read-only missing-translation discovery and immutable single-chapter plan.

Offline by default. This preparer has no mode-change/generation HTTP channel;
future Python protocol proof must consume the separate durable claims first.
"""
import argparse,json,resource
from datetime import datetime,timezone
from urllib.parse import urlencode
from annotation_experiment_model import digest
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from secure_translation_generation import TranslationGenerationStore
from translation_generation import bind,validate
from verify_translation_preflight import TranslationProbe,TranslationWebProbe,PLATFORM,membership,catalog,catalog_body,save_refreshed_web_session,PUBLIC_QUERY,PUBLIC_QUERIES
from verify_eink_login import BASE
from verify_web_source_progress import BASE as WEB
from translation_observation import position,observation
from native_initial_position import counts
from shelf_flag_change_contract import state_hash
from translation_source import chapter_title,structural_title,admit_source


class Native(TranslationProbe):
    def __init__(self,*,public_query=PUBLIC_QUERY):super().__init__(public_query=public_query);self.reads=0
    def guard(self,stage,url,body):
        if self.reads>=128:raise ValueError('translation_generation/read_limit')
        if stage=='progress' and body is None and any(url==BASE+'/book/getProgress?'+urlencode(dict(bookId=book)) for book in self.allowed_ids):return
        return super().guard(stage,url,body)
    def request(self,*args,**kwargs):
        result=super().request(*args,**kwargs);self.reads+=1;return result


class Web(TranslationWebProbe):
    def guard(self,stage,url,body):
        if self.authenticated and self.book_id and body is None:
            if stage=='progress' and url==WEB+'/web/book/getProgress?'+urlencode(dict(bookId=self.book_id)):return
            if stage=='generation_shelf' and url==WEB+'/web/shelf/sync':return
        return super().guard(stage,url,body)


def snapshot(api,web,grant):
    book=web.book_id
    raw=api.request('progress',BASE+'/book/getProgress?'+urlencode(dict(bookId=book)),credentials=grant)
    remote=web.request('progress',WEB+'/web/book/getProgress?'+urlencode(dict(bookId=book)))
    nshelf=api.request('shelf',BASE+'/shelf/sync',credentials=grant)
    wshelf=web.request('generation_shelf',WEB+'/web/shelf/sync')
    native_observed,web_observed=observation(raw,book,'native'),observation(remote,book,'web')
    if not native_observed['position_present'] or not web_observed['position_present']:
        if native_observed['position_present']!=web_observed['position_present']:raise ValueError('translation_generation/mixed_position_presence')
        # A distinct, fully observed baseline for this non-progress operation.
        # Never create a zero progress point or infer unreported time counters.
        return dict(kind='explicit-unrecorded-translation-baseline-v1',native=native_observed,web=web_observed,
            native_shelf=state_hash(nshelf),web_shelf=state_hash(wshelf))
    return dict(native=position(raw,book,'native'),web=position(remote,book,'web'),counts=counts(raw,book),
        native_shelf=state_hash(nshelf),web_shelf=state_hash(wshelf))


def inspect(api,web,grant,report,expected=None,*,chapter_offset=0):
    if type(chapter_offset) is not int or not 0<=chapter_offset<=19999:raise ValueError('translation_generation/chapter_offset')
    api.inspect(grant,2,True)
    if api.member['paying'] is not True:raise ValueError('translation_generation/member_required')
    report.update(paying_member_verified=True,sampled_books=len(api.samples),candidate_chapters_checked=0,
        existing_translation_chapters=0,empty_content_chapters=0,untranslated_content_candidates=0,chapter_offset=chapter_offset,
        structural_chapters_skipped=0,structural_sources_skipped=0,nonprose_sources_skipped=0)
    for sample in api.samples:
        model=sample['expected']
        if expected and model['book_id']!=expected['book_id']:continue
        safe=[row for row in model['chapters'] if row['free_or_owned'] and type(row.get('wordCount')) is int and row['wordCount']>=200 and row['uid']>0]
        nonstructural=[]
        for row in safe:
            if structural_title(chapter_title(sample,row['uid'])):report['structural_chapters_skipped']+=1
            else:nonstructural.append(row)
        safe=nonstructural
        safe.sort(key=lambda row:(row.get('transWordCount',0)>0,row['uid']))
        if expected:safe=[row for row in safe if row['uid']==expected['chapter_uid']]
        else:safe=safe[chapter_offset:chapter_offset+4]
        for row in safe[:4]:
            result=web.inspect_content(sample,row['uid']);report['candidate_chapters_checked']+=1
            content=web.content_sample
            if not result.get('content_decoded') or not content:
                report['empty_content_chapters']+=1;continue
            if result['nonempty_translation_blocks']:
                report['existing_translation_chapters']+=1
                if expected:raise ValueError('translation_generation/content_changed')
                continue
            report['untranslated_content_candidates']+=1
            title=chapter_title(sample,row['uid'])
            try:admit_source(content['source'],title)
            except ValueError as error:
                if str(error)=='translation_generation/not_english_prose':report['nonprose_sources_skipped']+=1;continue
                if str(error)=='translation_generation/structural_source':report['structural_sources_skipped']+=1;continue
                raise
            baseline=snapshot(api,web,grant)
            plan=bind(web.vid,grant,api.member,model,row,content['source'],baseline,chapter_title=title)
            # Independently repeat metadata/catalog and content; never label
            # the first response a fresh source witness for itself.
            info=api.request('book',BASE+'/book/info?'+urlencode(dict(bookId=model['book_id'])),credentials=grant)
            again_raw=api.request('catalog',BASE+'/book/chapterInfos',body=catalog_body(model['book_id']),credentials=grant)
            again=catalog(again_raw,model['book_id'],info)
            if again!=model:raise ValueError('translation_generation/catalog_changed')
            web.inspect_content(sample,row['uid'])
            if not web.content_sample or digest(web.content_sample['source'])!=plan['source_sha256'] or snapshot(api,web,grant)!=baseline:
                raise ValueError('translation_generation/baseline_changed')
            admit_source(web.content_sample['source'],chapter_title(dict(book_id=model['book_id'],source=again_raw),row['uid']))
            if expected and plan!=validate(expected):raise ValueError('translation_generation/plan_changed')
            unrecorded=baseline.get('kind')=='explicit-unrecorded-translation-baseline-v1'
            report.update(source_has_original_only=True,source_read_twice=True,position_presence_reported_fields_shelf_stable=True,
                baseline_kind='explicit_unrecorded' if unrecorded else 'recorded',native_complete_counters_verified=not unrecorded,
                explicit_free_or_owned=True,chapter_count_in_plan=1,english_prose_sample_verified=True)
            if not unrecorded:report['positions_counts_shelf_stable']=True
            else:report['reported_time_fields']={k:len(baseline[k]['counters']) for k in ('native','web')}
            return plan
    raise ValueError('translation_generation/no_missing_sample')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--chapter-offset',type=int,default=0)
    parser.add_argument('--query',choices=PUBLIC_QUERIES,default=PUBLIC_QUERY)
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--prepare',action='store_true');mode.add_argument('--dry-run',action='store_true')
    args=parser.parse_args(argv)
    if (args.prepare or args.dry_run) and not args.saved_session:parser.error('saved access required')
    if not 0<=args.chapter_offset<=19999 or args.chapter_offset and (not args.saved_session or args.dry_run):parser.error('bounded discovery offset requires saved access, not a stored-plan recheck')
    if args.query!=PUBLIC_QUERY and (not args.saved_session or args.prepare or args.dry_run):parser.error('additional public searches are read-only discovery only')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
        translation_mode_requests=0,generation_requests=0,authentication_posts=0,trial_activations=0,purchases=0,private_data_on_regular_disk=False)
    saved=grant=web=api=None
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid'])
            web=Web();web.vid=saved['vid']
            for k,v in saved['cookies'].items():web.set_cookie(k,v)
            web.verify_account();api=Native(public_query=args.query);store=TranslationGenerationStore();state,_receipt=store.read()
            if args.prepare and state is not None:raise ValueError('translation_generation/consumed')
            if args.dry_run and (not state or state['phase']!='prepared'):raise ValueError('translation_generation/not_prepared')
            plan=inspect(api,web,grant,report,state['plan'] if args.dry_run else None,chapter_offset=args.chapter_offset)
            web.verify_account()
            if save_refreshed_web_session(SessionStore(),saved,web):
                report['refreshed_web_session_saved']=True;saved=SessionStore().load()
            report['result']='MISSING_TRANSLATION_READONLY_VERIFIED'
            if args.prepare:
                store.reserve(plan);report['result']='TRANSLATION_PLAN_PREPARED'
            if args.dry_run:report['result']='TRANSLATION_PLAN_DISARMED_VERIFIED'
    except Exception as error:
        report['result']='UNVERIFIED';reason=str(error)
        allowed={'translation_generation/'+s for s in ('member_required','no_missing_sample','consumed','not_prepared','content_changed','catalog_changed','baseline_changed','plan_changed','mixed_position_presence')}
        report['reason']=reason if reason in allowed else 'translation_generation/preflight_unavailable'
    finally:
        if api:report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in api.report['stages']]
        if web:
            if web.authenticated:
                try:
                    web.verify_account()
                    if save_refreshed_web_session(SessionStore(),saved,web):report['refreshed_web_session_saved']=True
                except Exception:
                    report.update(result='UNVERIFIED',reason='translation_generation/final_account_unavailable')
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']];web.close()
        for item in (grant,saved):
            if item:item.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
