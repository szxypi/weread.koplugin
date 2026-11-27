"""Host-side supervisor for one native chapter selection thought lifecycle.

A durable four-slot intent precedes execution. Each operation is scoped to the
exact selected book, quote and new thought; no failed operation is replayed.
"""
from copy import deepcopy
import secrets
import subprocess

from annotation_experiment_model import digest,note_text,valid_key
from native_trial_pipe import Frames,reply,stop,write_initial
from selection_trial_model import TXT_PROTOCOL,fingerprint


def execute(probe,credentials,store,receipt,command,*,source,armed,report,on_final=None,offline_draft=False):
    if type(armed) is not bool or type(offline_draft) is not bool or not command or not isinstance(source,dict):raise ValueError('direct_selection_trial/input')
    state,current=store.read();probe.current()
    if state is None or current!=receipt or state['phase']!='prepared' or state['plan']!=probe.plan.bound:
        raise ValueError('direct_selection_trial/intent')
    txt=probe.plan.bound['protocol']==TXT_PROTOCOL
    if (source['book_id']!=probe.plan.bound['book_id'] or source['uid']!=probe.plan.bound['chapter_uid']
            or source['source_sha256']!=probe.payload['source_raw_sha256']
            or (source.get('plain_text') is True)!=txt
            or txt and (source['book_version']!=0 or any(source[k]!=probe.plan.bound[k]
                for k in ('source_sha256','chapter_idx','source_bytes')))):raise ValueError('direct_selection_trial/source')
    probe.baseline(credentials,'direct_selection_before_launch')
    cfg=deepcopy(probe.payload['selection_preview']);token=secrets.token_hex(16)
    payload=dict(credentials=credentials,book_id=source['book_id'],uid=source['uid'],book_version=source['book_version'],
        source_sha256=source['source_sha256'],web_cookies=probe.payload['cookies'],selection_preview=cfg,
        trial=dict(armed=armed,rpc_token=token,original_ids=sorted(probe.plan.baseline['thoughts']),
            edited_text=note_text(probe.plan.bound['nonce'],True)))
    if txt:payload.update(plain_text=True,chapter_idx=source['chapter_idx'],source_bytes=source['source_bytes'])
    if offline_draft:payload['trial']['offline_draft']=True
    # The caller never sends real credentials to a mock endpoint.
    if source.get('mock_endpoint') is not None:payload['mock_endpoint']=source['mock_endpoint']
    if armed:receipt=store.claim(receipt)
    child=frames=None;waiting=None;claims=steps=0;target=None;runner=None
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=600)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':runner=value;break
            waiting=value;event=value.get('kind');seq=value.get('seq')
            if type(seq) is not int or not 1<=seq<=3:raise ValueError('direct_selection_trial/sequence')
            if event in ('claim','dry_body'):
                if (event!=('claim' if armed else 'dry_body') or set(value)!={'kind','seq','body'}
                        or seq!=steps+1 or claims!=steps or not armed and seq!=1):raise ValueError('direct_selection_trial/sequence')
                body=cfg['body'] if seq==1 else {'reviewId':target,**({'content':payload['trial']['edited_text']} if seq==2 else {})}
                if value['body']!=body:raise ValueError('direct_selection_trial/body')
                journal,owned=store.read()
                if (owned!=receipt or journal is None or journal['phase']!=('pending' if armed else 'prepared')
                        or journal['plan']!=probe.plan.bound or journal['native_steps']!=steps):
                    raise ValueError('direct_selection_trial/intent')
                if seq==1:probe.baseline(credentials,'direct_selection_before_create')
                else:probe.read_step(credentials,seq-1,target)
                claims=seq
            elif event=='verified':
                if (not armed or set(value)!={'kind','seq','created_id'} or seq!=claims or seq!=steps+1
                        or not valid_key(value['created_id']) or value['created_id'] in probe.plan.baseline['thoughts']
                        or target is not None and value['created_id']!=target):raise ValueError('direct_selection_trial/sequence')
                target=value['created_id'];mark=probe.read_step(credentials,seq,target)
                receipt=store.native_step(receipt,seq,target,mark);steps=seq
                if seq==3:receipt=probe.cleanup(credentials,store,receipt)
            else:raise ValueError('direct_selection_trial/event')
            reply(child.stdin,dict(kind=event,seq=seq,ok=True));waiting=None
        if (child.wait(timeout=15) or not isinstance(runner,dict) or runner.get('result')!='PASS'
                or runner.get('profile_removed') is not True or runner.get('credential_file_audit') is not True
                or runner.get('installed_bytes_match') is not True or runner.get('steps')!=(3 if armed else 0)
                or runner.get('posts')!=(3 if armed else 0) or runner.get('blocked') is not (not armed)
                or claims!=(3 if armed else 1) or steps!=(3 if armed else 0)):
            raise ValueError('direct_selection_trial/runner')
        probe.final(credentials,probe.payload['cookies']) if armed else probe.baseline(credentials,'direct_selection_after_dry_run')
        if on_final is not None:on_final()
        if armed:
            receipt=store.complete(receipt);store.finish(receipt)
            if store.pending():raise ValueError('direct_selection_trial/intent')
        report.update(result='DIRECT_SELECTION_THOUGHT_ROUNDTRIP_VERIFIED' if armed else 'DIRECT_SELECTION_THOUGHT_DRY_RUN_VERIFIED',
            claims=claims,independent_steps=steps,account_data_posts=3+probe.cleanup_posts if armed and not source.get('mock_endpoint') else 0,
            synthetic_posts=3+probe.cleanup_posts if armed and source.get('mock_endpoint') else 0,cleanup_posts=probe.cleanup_posts,temporary_profile_removed=True,credential_file_audit=True,
            installed_bytes_match=True,no_automatic_replay=True,intent_fingerprint=fingerprint(probe.plan.bound))
        if txt:
            report['baseline_fingerprint']=digest({key:value for key,value in probe.plan.bound.items() if key!='nonce'})
        if offline_draft:report['offline_draft_submitted']=armed;report['offline_draft_prepared']=True
        if armed:
            report['original_records_restored']=True
            report['derived_chapter_metadata_changed']=probe.derived_chapter_metadata_changed
            report['original_state_restored']=not probe.derived_chapter_metadata_changed
        else:report['original_native_state_unchanged']=True
    except (Exception,KeyboardInterrupt):
        if armed:report.pop('account_data_posts',None)
        report.update(result='UNVERIFIED',claims=claims,independent_steps=steps,no_automatic_replay=True,
            account_data_posts_upper_bound=claims+probe.cleanup_posts if armed and not source.get('mock_endpoint') else 0)
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
