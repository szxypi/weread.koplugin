"""Supervise one native-chapter highlight creation and exact removal."""
from copy import deepcopy
import secrets
import subprocess

from annotation_experiment_model import digest,valid_key
from highlight_trial_model import bind_native,bind_txt as bind_highlight_txt
from native_trial_pipe import Frames,reply,stop,write_initial
from verify_owner_reading import reading_position
from verify_web_source_progress import BASE


def execute(probe,credentials,store,command,*,source,armed,report,on_final=None,bookmark=False,on_created=None):
    if type(armed) is not bool or type(bookmark) is not bool or not command or not store.native or store.read()!=(None,None):
        raise ValueError('direct_highlight_trial/intent')
    if on_created is not None and (not bookmark or not callable(on_created)):
        raise ValueError('direct_highlight_trial/callback')
    probe.current();selection=probe.source;p=selection.plan
    txt=source.get('plain_text') is True
    if (source['book_id']!=p.bound['book_id'] or source['uid']!=p.bound['chapter_uid']
            or source['source_sha256']!=selection.payload['source_raw_sha256']
            or txt and (source['book_version']!=0 or source['chapter_idx']!=p.bound['chapter_idx']
                or source['source_sha256']!=p.bound['source_sha256'] or on_created is not None)):
        raise ValueError('direct_highlight_trial/source')
    selection.baseline(credentials,'direct_highlight_before_launch')
    if bookmark:
        from bookmark_trial_model import bind,bind_txt
        bound=bind_txt(p.bound,probe.body) if txt else bind(p.bound,probe.body,native=True)
    else:bound=bind_highlight_txt(p.bound,probe.body) if txt else bind_native(p.bound,probe.body)
    token=secrets.token_hex(16)
    payload=dict(credentials=credentials,book_id=source['book_id'],uid=source['uid'],book_version=source['book_version'],
        source_sha256=source['source_sha256'],web_cookies=selection.payload['cookies'],
        trial=dict(armed=armed,rpc_token=token,original_ids=sorted(p.baseline['marks']['updated']),create_body=deepcopy(probe.body)))
    if txt:payload.update(plain_text=True,chapter_idx=source['chapter_idx'],source_bytes=source['source_bytes'])
    else:payload['selection_preview']=deepcopy(selection.payload['selection_preview'])
    if bookmark:payload['trial']['bookmark']=True
    if armed and on_created is not None:payload['trial']['cross_check']=True
    if source.get('mock_endpoint') is not None:payload['mock_endpoint']=source['mock_endpoint']
    receipt=store.reserve(bound) if armed else None
    child=frames=None;waiting=None;claims=steps=0;target=runner=None;cross_verified=None
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=1200 if on_created else 600)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':runner=value;break
            waiting=value;event=value.get('kind');seq=value.get('seq')
            if type(seq) is not int or not 1<=seq<=2:raise ValueError('direct_highlight_trial/sequence')
            if event in ('claim','dry_body'):
                if (event!=('claim' if armed else 'dry_body') or set(value)!={'kind','seq','body'}
                        or seq!=steps+1 or claims!=steps or not armed and seq!=1):raise ValueError('direct_highlight_trial/sequence')
                expected=probe.body if seq==1 else {'bookmarkIds':[target['id']]}
                if value['body']!=expected:raise ValueError('direct_highlight_trial/body')
                if seq==1:
                    if armed and not store.owns(receipt,'create_pending'):raise ValueError('direct_highlight_trial/intent')
                    selection.baseline(credentials,'direct_highlight_before_create')
                else:
                    latest,_=probe.read(credentials)
                    if latest!=target or not store.owns(receipt,'delete_pending'):raise ValueError('direct_highlight_trial/target')
                claims=seq
            elif event=='verified':
                if (not armed or set(value)!={'kind','seq','created_id'} or seq!=claims or seq!=steps+1
                        or not valid_key(value['created_id']) or value['created_id'] in p.baseline['marks']['updated']):
                    raise ValueError('direct_highlight_trial/sequence')
                if seq==1:
                    target,_=probe.read(credentials)
                    if target['id']!=value['created_id']:raise ValueError('direct_highlight_trial/target')
                    probe.target=target;receipt=store.advance(receipt,'created',target=target)
                    latest,_=probe.read(credentials)
                    if latest!=target:raise ValueError('direct_highlight_trial/target')
                    if on_created is not None:
                        try:cross_verified=on_created(target) is True
                        except Exception:cross_verified=False
                        latest,_=probe.read(credentials)
                        if latest!=target:raise ValueError('direct_highlight_trial/target')
                    receipt=store.advance(receipt,'delete_pending')
                else:
                    if target is None or value['created_id']!=target['id'] or not store.owns(receipt,'delete_pending'):
                        raise ValueError('direct_highlight_trial/target')
                    probe.read(credentials,deleted=True)
                steps=seq
            else:raise ValueError('direct_highlight_trial/event')
            reply(child.stdin,dict(kind=event,seq=seq,ok=True));waiting=None
        if (child.wait(timeout=15) or not isinstance(runner,dict) or runner.get('result')!='PASS'
                or runner.get('profile_removed') is not True or runner.get('credential_file_audit') is not True
                or runner.get('installed_bytes_match') is not True or runner.get('steps')!=(2 if armed else 0)
                or runner.get('posts')!=(2 if armed else 0) or runner.get('blocked') is not (not armed)
                or claims!=(2 if armed else 1) or steps!=(2 if armed else 0)):
            raise ValueError('direct_highlight_trial/runner')
        if armed:_target,final=probe.read(credentials,deleted=True)
        else:final=selection.baseline(credentials,'direct_highlight_after_dry_run')
        selection.web.verify_account()
        after=reading_position(selection.web.request('progress_after',BASE+'/web/book/getProgress?bookId='+p.bound['book_id']),p.bound['book_id'])
        if after!=p.web_position:raise ValueError('direct_highlight_trial/web_position')
        if on_final is not None:on_final()
        if armed:
            receipt=store.advance(receipt,'verified');store.finish(receipt)
        if store.read()!=(None,None):raise ValueError('direct_highlight_trial/intent')
        changed=final['marks']['chapters']!=p.baseline['marks']['chapters']
        report.update(result=('DIRECT_BOOKMARK_ROUNDTRIP_VERIFIED' if armed else 'DIRECT_BOOKMARK_DRY_RUN_VERIFIED') if bookmark
                else ('DIRECT_HIGHLIGHT_ROUNDTRIP_VERIFIED' if armed else 'DIRECT_HIGHLIGHT_DRY_RUN_VERIFIED'),
            intent_fingerprint=digest(bound),claims=claims,independent_steps=steps,
            account_data_posts=2 if armed and not source.get('mock_endpoint') else 0,
            synthetic_posts=2 if armed and source.get('mock_endpoint') else 0,
            original_records_unchanged=True,web_position_unchanged=True,derived_chapter_metadata_changed=changed,
            original_state_unchanged=not changed,temporary_profile_removed=True,credential_file_audit=True,
            installed_bytes_match=True,no_automatic_replay=True)
        if armed and on_created is not None:
            report.update(cross_chapter_verified=cross_verified is True,cleanup_completed=True)
            if cross_verified is not True:report['result']='UNVERIFIED'
    except (Exception,KeyboardInterrupt):
        if armed:report.pop('account_data_posts',None)
        report.update(result='UNVERIFIED',claims=claims,independent_steps=steps,no_automatic_replay=True,
            account_data_posts_upper_bound=claims if armed and not source.get('mock_endpoint') else 0)
        if isinstance(runner,dict):
            for key in ('phase','probe_line','profile_removed'):
                if key in runner:report['runner_'+key]=runner[key]
        if child is not None and frames is not None and child.poll() is None and waiting is not None:
            try:reply(child.stdin,dict(kind=waiting.get('kind'),seq=waiting.get('seq'),ok=False))
            except Exception:pass
        raise
    finally:
        if child is not None:stop(child)
        payload.clear()
