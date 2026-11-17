#!/usr/bin/env python3
"""One-shot Python translation protocol proof. Offline unless explicitly selected."""
import argparse,base64,json,resource,time
from datetime import datetime,timezone
from urllib.parse import urlencode
from urllib.request import build_opener
from annotation_experiment_model import digest
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from secure_translation_generation import TranslationGenerationStore
from native_time_capture import NativeCaptureStore
from readtime_history_capture import CaptureStore
from translation_generation import validate,mode_ack,status
from translation_dispatch import send_once
from translation_wire import successful_http
from translation_result import original_signature,catalog_result,make_proof,restore_catalog,validate_proof
from verify_translation_generation import Native,Web,inspect,snapshot
from verify_translation_preflight import catalog,catalog_body,save_refreshed_web_session
from verify_eink_login import BASE,NoRedirect


def journal_report(state):
    if state is None:return dict(phase='absent',mode_claims=0,generation_claims=0,receipts=[])
    return dict(phase=state['phase'],mode_claims=state['requests'].count('mode'),generation_claims=state['requests'].count('generation'),
        receipts=[dict(operation=a['operation'],http_status=a['wire']['http_status'],body_truncated=a['wire']['body_truncated'],
            captured_bytes=len(base64.b64decode(a['wire']['body_base64']))) for a in state['acks'] if 'wire' in a])


def capture_baseline(api,web,grant,plan,*,current):
    current()
    expected=validate(plan)
    if not web.content_sample or digest(web.content_sample['source'])!=expected['source_sha256']:raise ValueError('translation_trial/source')
    original=original_signature(web.content_sample['source'])
    observed=snapshot(api,web,grant)
    if digest(observed)!=expected['baseline_sha256']:raise ValueError('translation_trial/baseline')
    # Retain the actual original and baseline before the generation write.
    return original,observed


def read_result(api,web,grant,plan,sample,original,baseline,semantic,*,current,wait=time.sleep):
    def unchanged(value):return digest(value)==baseline if isinstance(baseline,str) else value==baseline
    ready_source=ready_model=None
    limit=1 if semantic['kind']=='stopped_unavailable' else 6
    for attempt in range(limit):
        current()
        info=api.request('book',BASE+'/book/info?'+urlencode(dict(bookId=plan['book_id'])),credentials=grant)
        model=catalog(api.request('catalog',BASE+'/book/chapterInfos',body=catalog_body(plan['book_id']),credentials=grant),plan['book_id'],info)
        version=catalog_result(sample['expected'],model,plan['chapter_uid'])
        result=web.inspect_content(sample,plan['chapter_uid']);content=web.content_sample
        if not result.get('content_decoded') or not content:raise ValueError('translation_trial/content')
        if original_signature(content['source'])!=original:raise ValueError('translation_trial/original_changed')
        if not unchanged(snapshot(api,web,grant)):raise ValueError('translation_trial/baseline_changed')
        if (result.get('nonempty_translation_blocks',0)>0 and type(version) is int and version>0
                and semantic['kind'] in ('ready','pending') and version>=plan['translate_version']
                and (semantic['version'] is None or version>=semantic['version'])):
            ready_source=content['source'];ready_model=model;break
        if attempt+1<limit:wait(2)
    if ready_source is None:raise ValueError('translation_trial/not_ready')
    current();web.inspect_content(sample,plan['chapter_uid'])
    info=api.request('book',BASE+'/book/info?'+urlencode(dict(bookId=plan['book_id'])),credentials=grant)
    final_model=catalog(api.request('catalog',BASE+'/book/chapterInfos',body=catalog_body(plan['book_id']),credentials=grant),plan['book_id'],info)
    if not web.content_sample or web.content_sample['source']!=ready_source or final_model!=ready_model or not unchanged(snapshot(api,web,grant)):raise ValueError('translation_trial/final_changed')
    return dict(actual_translated_content_read_twice=True,original_visible_text_unchanged=True,
        catalog_changed_only_current_translation_fields=True,position_presence_reported_fields_shelf_unchanged=True,
        positive_translation_version=True)


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');p.add_argument('--chapter-offset',type=int,default=0)
    modes=p.add_mutually_exclusive_group()
    for flag in ('dry-run','apply','mode-only','generation-only','inspect-result'):modes.add_argument('--'+flag,action='store_true')
    a=p.parse_args(argv);selected=a.dry_run or a.apply or a.mode_only or a.generation_only or a.inspect_result
    if bool(a.saved_session)!=bool(selected) or not 0<=a.chapter_offset<=19999 or a.chapter_offset and not a.dry_run:p.error('explicit saved access and one operation required; offset is for disarmed discovery only')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),mode_request_attempts=0,generation_request_attempts=0,
        authentication_posts=0,trial_activations=0,purchases=0,real_screenshots=0,private_data_on_regular_disk=False)
    saved=grant=web=store=plan=api=None;apis=[];phase='init'
    try:
        if selected:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0));session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
            capture,old_capture=NativeCaptureStore(),CaptureStore();retained=(capture.read(),old_capture.read())
            store=TranslationGenerationStore();state,receipt=store.read()
            expected_phase='submitted' if a.inspect_result else 'mode_responded' if a.generation_only else 'prepared'
            allowed={'prepared','mode_responded'} if a.dry_run else {expected_phase}
            if state is not None and state['phase'] not in allowed:raise ValueError('translation_trial/consumed')
            if state is None and not a.dry_run:raise ValueError('translation_trial/not_prepared')
            if state is not None and a.chapter_offset:raise ValueError('translation_trial/selector')
            if state is not None and state['phase']=='mode_responded':
                ack=state['acks'][0]
                if 'wire' not in ack or not successful_http(ack['wire']):raise ValueError('translation_trial/mode_unconfirmed')
                mode_ack(ack['response'],state['plan'])
            web=Web();web.vid=saved['vid']
            for k,v in saved['cookies'].items():web.set_cookie(k,v)
            def current():
                if native.load(saved['vid'])!=grant or session.load()!=saved or (capture.read(),old_capture.read())!=retained:raise ValueError('translation_trial/context_changed')
            def preflight(expected=None):
                current();web.verify_account();api=Native();apis.append(api);fixed={}
                plan=inspect(api,web,grant,fixed,expected,chapter_offset=a.chapter_offset if expected is None else 0)
                for retained_record,_ in retained:
                    if retained_record and retained_record.get('plan',{}).get('book_id')==plan['book_id']:raise ValueError('translation_trial/capture_book')
                report['preflight']=fixed;return api,plan
            if a.inspect_result:
                phase='inspect_result';plan=validate(state['plan']);proof=validate_proof(state.get('proof'),plan)
                if plan['owner']!=saved['vid'] or any('wire' not in ack or not successful_http(ack['wire']) for ack in state['acks']):raise ValueError('translation_trial/mode_unconfirmed')
                mode_ack(state['acks'][0]['response'],plan);semantic=status(state['acks'][1]['response'],plan)
                current();web.verify_account();api=Native();apis.append(api);api.allowed_ids={plan['book_id']}
                info=api.request('book',BASE+'/book/info?'+urlencode(dict(bookId=plan['book_id'])),credentials=grant)
                model=catalog(api.request('catalog',BASE+'/book/chapterInfos',body=catalog_body(plan['book_id']),credentials=grant),plan['book_id'],info)
                sample=dict(book_id=plan['book_id'],expected=restore_catalog(model,plan,proof));web.book_id=plan['book_id']
                report.update(read_result(api,web,grant,plan,sample,proof['original_text_sha256'],plan['baseline_sha256'],semantic,current=current))
                if store.read()[1]!=receipt:raise ValueError('translation_trial/journal_changed')
                report.update(result='PASS_REAL_GENERATION_READONLY_INSPECTION',generation_ack_kind=semantic['kind'],journal_unchanged=True,
                    dispatch_grant_matches_current=digest(grant)==plan['grant_sha256'])
            else:
                phase='preflight';api,plan=preflight(state['plan'] if state else None)
            if a.dry_run:
                sample=next(s for s in api.samples if s['book_id']==plan['book_id'])
                original,baseline=capture_baseline(api,web,grant,plan,current=current)
                make_proof(sample['expected'],plan,original,baseline=baseline)
                report.update(result='TRANSLATION_DISPATCH_DISARMED_VERIFIED',durable_intent_present=state is not None,original_proof_fits_keychain=True)
            elif not a.inspect_result:
                sample=next(s for s in api.samples if s['book_id']==plan['book_id'])
                phase='bind_proof';original,baseline=capture_baseline(api,web,grant,plan,current=current)
                receipt=store.bind_proof(receipt,make_proof(sample['expected'],plan,original,baseline=baseline))
                class Transport:
                    def __init__(self):self.transport=build_opener(NoRedirect())
                    def open(self,request,**kw):
                        key='mode_request_attempts' if request.get_method()=='GET' else 'generation_request_attempts'
                        report[key]+=1;return self.transport.open(request,**kw)
                transport=Transport()
                if not a.generation_only:
                    phase='mode';receipt,_=send_once(store,receipt,'mode',grant,current=current,opener=transport)
                    if a.mode_only:report['result']='MODE_ACK_SAVED_VERIFIED'
                    else:
                        phase='between_operations';api,plan=preflight(plan);sample=next(s for s in api.samples if s['book_id']==plan['book_id'])
                else:
                    ack=state['acks'][0]
                    if 'wire' not in ack or not successful_http(ack['wire']):raise ValueError('translation_trial/mode_unconfirmed')
                    mode_ack(ack['response'],plan)
                if not a.mode_only:
                    phase='generation_baseline';original,baseline=capture_baseline(api,web,grant,plan,current=current)
                    phase='generation';receipt,semantic=send_once(store,receipt,'generation',grant,current=current,opener=transport)
                    report['generation_ack_kind']=semantic['kind'];phase='independent_result'
                    report.update(read_result(api,web,grant,plan,sample,original,baseline,semantic,current=current))
                    report['result']='PASS_REAL_SINGLE_CHAPTER_GENERATION'
            current();web.verify_account();report['retained_captures_and_native_grant_unchanged']=True
    except Exception as error:
        report.update(result='UNVERIFIED',phase=phase)
        reason=str(error)
        prefixes=('translation_trial/','translation_dispatch/','translation_generation/','translation_result/','translation_wire/')
        if reason.startswith(prefixes) and len(reason)<100 and reason.replace('_','').replace('/','').isalpha():report['reason']=reason
        if plan and api and web and store:
            try:
                recorded=store.read()[0]
                if recorded and recorded['requests']:
                    current();report['post_failure_baseline_check']='match' if digest(snapshot(api,web,grant))==plan['baseline_sha256'] else 'changed'
            except Exception:report['post_failure_baseline_check']='unavailable'
    finally:
        if store:
            try:report['journal']=journal_report(store.read()[0])
            except Exception:report['journal']=dict(phase='unreadable')
        report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for api in apis for r in api.report['stages']]
        if web:
            try:
                web.verify_account();save_refreshed_web_session(SessionStore(),saved,web)
            except Exception:report.update(result='UNVERIFIED',phase='final_account')
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']];web.close()
        for value in (grant,saved):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
