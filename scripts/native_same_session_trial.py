"""Independently gate upload and reading in one native plugin session."""
import base64,secrets,subprocess
from native_combined_upload_trial import _prepare_read,_verify_after,synthetic_source_verified
from native_personal_upload_ui_trial import launch as upload_preview
from native_trial_pipe import Frames,reply,stop,write_initial
from personal_upload_trial import hash_value
from reading_epub_trial import check,validate_reading
from run_native_personal_upload_ui import validate_stage as validate_upload
from secure_weread_session import SessionStore
from synthetic_upload_epub import build_reading
from verify_cb_progress import cb_id
from verify_eink_renewal import validate_credentials


def launch(plan,credentials,journal,target_receipt,probe,*,store=None):
    validate_reading(plan);validate_credentials(credentials)
    if credentials['vid']!=plan['owner'] or hash_value(credentials)!=plan['grant_sha256']:raise ValueError('combined/grant')
    if upload_preview(plan,credentials,armed=False,fixture='reading_epub_same')!={'preview':True}:raise ValueError('combined/preview')
    if not probe.grant_check(credentials) or not check(plan,credentials,probe.shelf(credentials)):raise ValueError('combined/changed')
    token=secrets.token_hex(16);payload=dict(credentials=credentials,name=plan['name'],shelf_books=plan['count'],rpc_token=token,
        permit_writes=True,fixture='reading_epub',body_base64=base64.b64encode(build_reading()).decode('ascii'),same_session=True)
    command=['docker','exec','-i','-w','/source','weread-validation','timeout','--signal=TERM','--kill-after=10','450',
        'python3','scripts/run_combined_same_session.py','--koreader','/validation/runtime/lib/koreader',
        '--candidate','/validation/pdf-original-manual-ui-1264-v2/candidate.zip','--width','1264','--height','1680','--dpi','300']
    child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE);store=store or SessionStore()
    try:
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=420);kind,step=frames.next()
        if kind!='STEP' or set(step)!={'seq','target'} or type(step['seq']) is not int or step['seq']!=1 or not cb_id(step['target']):raise ValueError('combined/upload')
        target=step['target'];state,receipt=journal.read();target_receipt.record(journal,receipt,plan,target)
        if not probe.grant_check(credentials) or not check(plan,credentials,probe.shelf(credentials),target,True):raise ValueError('combined/changed')
        reading,baseline=_prepare_read(target,credentials['vid'],store)
        reply(child.stdin,dict(seq=1,ok=True,payload=reading))
        kind,result=frames.next();code=child.wait(timeout=15)
        if (kind!='RESULT' or code or not isinstance(result,dict)
                or set(result)!={'result','profile_removed','installed','upload','stages','error','cookies'}
                or result['result']!='PASS' or result['profile_removed'] is not True or result['error']!='none'
                or not isinstance(result['installed'],dict) or set(result['installed'])!={'files','bytes_match'}
                or result['installed']['bytes_match'] is not True or type(result['installed']['files']) is not int
                or not 1<=result['installed']['files']<=1000 or not isinstance(result['stages'],list) or result['stages']):
            raise ValueError('combined/result')
        upload=validate_upload(result['upload'],True,same_session=True)
        if upload['target']!=target:raise ValueError('combined/target')
        if upload['web_cookies']!=result['cookies']:raise ValueError('combined/session')
        _verify_after(target,credentials['vid'],baseline,result['cookies'],store)
        return dict(target=target,counts=dict(shelf=upload['native_gets'],credential=upload['credential_gets'],
            put=upload['puts'],notify=upload['notifies'],denied=upload['denied']))
    finally:
        payload.clear();stop(child)
