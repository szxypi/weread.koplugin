"""Read-only manual PDF association in an anonymous, disposable native profile."""
import base64,json,re,secrets,subprocess
from run_native_personal_upload_ui import validate_input,validate_stage
from synthetic_upload_rich_pdf import build
from verify_eink_renewal import validate_credentials


def launch(credentials,target,shelf_books,*,width,height,dpi):
    validate_credentials(credentials)
    if (not isinstance(target,str) or re.fullmatch(r'CB_[A-Za-z0-9]{1,64}',target) is None
        or type(shelf_books) is not int or not 1<=shelf_books<=5000
        or (width,height,dpi) not in ((600,800,167),(1264,1680,300))):raise ValueError('manual_pdf/input')
    token=secrets.token_hex(16)
    payload=dict(credentials=credentials,name='KOReaderSynthetic-'+secrets.token_hex(8)+'.pdf',shelf_books=shelf_books,
        rpc_token=token,permit_writes=False,fixture='rich_pdf',body_base64=base64.b64encode(build()).decode('ascii'),manual_target=target)
    validate_input(payload,False,None)
    raw=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode();framed=str(len(raw)).encode()+b'\n'+raw
    command=['docker','exec','-i','-w','/source','weread-validation','timeout','--signal=TERM','--kill-after=10','165',
        'python3','scripts/run_native_personal_upload_ui.py','--koreader','/validation/runtime/lib/koreader',
        '--candidate','/validation/pdf-original-unlink-ui-1264-v1/candidate.zip','--width',str(width),'--height',str(height),'--dpi',str(dpi)]
    child=subprocess.run(command,input=framed,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=190,check=False)
    prefix=('WEREAD_NATIVE_THOUGHT_'+token+'_RESULT=').encode()
    frames=[line[len(prefix):] for line in child.stdout.splitlines() if line.startswith(prefix)]
    if child.returncode or len(frames)!=1 or len(frames[0])>16384:raise ValueError('manual_pdf/child')
    value=json.loads(frames[0])
    if (not isinstance(value,dict) or set(value)!={'result','profile_removed','installed','stage'} or value['result']!='PASS'
        or value['profile_removed'] is not True or not isinstance(value['installed'],dict)
        or set(value['installed'])!={'files','bytes_match'} or value['installed']['bytes_match'] is not True
        or type(value['installed']['files']) is not int or not 1<=value['installed']['files']<=1000):raise ValueError('manual_pdf/child')
    stage=validate_stage(value['stage'],False,manual_original=True)
    return dict(result='MANUAL_LOCAL_PDF_NATIVE_VERIFIED',profile_removed=True,credential_audit=stage['credential_audit'],
        local_selection_confirmed=True,cancel_preserved=True,unlink_cancel_preserved=True,local_unlinked=True,original_preserved=True,local_reader_opened=True,cloud_identity_absent=True,
        account_data_writes=0,authentication_posts=0,network_requests=0,screenshots=0)
