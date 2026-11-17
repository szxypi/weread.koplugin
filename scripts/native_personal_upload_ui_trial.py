"""Separate one-shot owner UI trial; credentials and results stay on pipes."""
import base64,json,re,secrets,subprocess,tempfile
from pathlib import Path
from native_personal_upload_trial import Journal as BaseJournal
from personal_upload_trial import hash_value,validate
from run_native_personal_upload_ui import validate_stage
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from verify_eink_renewal import validate_credentials

SERVICE='org.codex.weread.goal-native-upload-ui-trial-v1'


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-native-upload-ui-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock)


def launch(plan,credentials,*,armed,fixture='txt'):
    if fixture=='txt':validate(plan)
    elif fixture=='epub':
        from synthetic_epub_trial import validate_epub
        validate_epub(plan)
    elif fixture=='large_epub':
        from large_epub_trial import validate_large
        validate_large(plan)
    elif fixture=='near_epub':
        from near_limit_epub_trial import validate_near
        validate_near(plan)
    elif fixture=='exact_epub':
        from exact_limit_epub_trial import validate_exact
        validate_exact(plan)
    elif fixture=='reading_epub':
        from reading_epub_trial import validate_reading
        validate_reading(plan)
    elif fixture=='rich_pdf':
        from reading_rich_pdf_trial import validate_rich
        validate_rich(plan)
    elif fixture in ('pdf','mobi','azw3'):
        from synthetic_pdf_trial import validate_pdf
        from synthetic_format_trial import validator
        (validate_pdf if fixture=='pdf' else validator(fixture))(plan)
    else:raise ValueError('native_upload_ui/input')
    validate_credentials(credentials)
    if type(armed) is not bool or credentials['vid']!=plan['owner'] or hash_value(credentials)!=plan['grant_sha256']:raise ValueError('native_upload_ui/input')
    token=secrets.token_hex(16)
    payload=dict(credentials=credentials,name=plan['name'],shelf_books=plan['count'],rpc_token=token,permit_writes=armed)
    if fixture=='epub':
        from synthetic_upload_epub import build
        payload.update(fixture='epub',body_base64=base64.b64encode(build()).decode('ascii'))
    elif fixture=='reading_epub':
        from synthetic_upload_epub import build_reading
        payload.update(fixture='reading_epub',body_base64=base64.b64encode(build_reading()).decode('ascii'),combined_upload=True)
    elif fixture in ('large_epub','near_epub','exact_epub'):payload['fixture']=fixture
    elif fixture=='rich_pdf':
        from synthetic_upload_rich_pdf import build
        payload.update(fixture=fixture,body_base64=base64.b64encode(build()).decode('ascii'))
    elif fixture in ('pdf','mobi','azw3'):
        from synthetic_pdf_trial import build as build_pdf
        from synthetic_format_trial import build as build_format
        body=build_pdf() if fixture=='pdf' else build_format(fixture)
        payload.update(fixture=fixture,body_base64=base64.b64encode(body).decode('ascii'))
    raw=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode();framed=str(len(raw)).encode()+b'\n'+raw
    args=['docker','exec','-i','-w','/source','weread-validation','timeout','--signal=TERM','--kill-after=10','1000' if fixture in ('near_epub','exact_epub') else '165',
        'python3','scripts/run_native_personal_upload_ui.py','--koreader','/validation/runtime/lib/koreader',
        '--candidate','/validation/pdf-original-ui-1264-v4/candidate.zip' if fixture=='rich_pdf' else '/validation/large-delay-ui-1264-v1/candidate.zip','--width','1264','--height','1680','--dpi','300']
    if armed:args.append('--armed')
    result=subprocess.run(args,input=framed,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=1020 if fixture in ('near_epub','exact_epub') else 190,check=False)
    prefix=('WEREAD_NATIVE_THOUGHT_'+token+'_RESULT=').encode()
    frames=[line[len(prefix):] for line in result.stdout.splitlines() if line.startswith(prefix)]
    if result.returncode or len(frames)!=1 or len(frames[0])>16384:raise ValueError('native_upload_ui/child')
    value=json.loads(frames[0])
    if (not isinstance(value,dict) or set(value)!={'result','profile_removed','installed','stage'} or value['result']!='PASS'
            or value['profile_removed'] is not True or not isinstance(value['installed'],dict)
            or set(value['installed'])!={'files','bytes_match'} or value['installed']['bytes_match'] is not True
            or type(value['installed']['files']) is not int or not 1<=value['installed']['files']<=1000):raise ValueError('native_upload_ui/child')
    stage=validate_stage(value['stage'],armed,local_original=fixture=='rich_pdf' and armed)
    if not armed:return dict(preview=True)
    result=dict(target=stage['target'],counts=dict(shelf=stage['native_gets'],credential=stage['credential_gets'],
        put=stage['puts'],notify=stage['notifies'],denied=stage['denied']))
    if fixture=='rich_pdf':result['local_original']=True
    return result


def guarded_launch(plan,credentials,verify_fresh):
    if launch(plan,credentials,armed=False)!={'preview':True}:raise ValueError('native_upload_ui/preview')
    if verify_fresh(plan,credentials) is not True:raise ValueError('native_upload_ui/changed')
    return launch(plan,credentials,armed=True)
