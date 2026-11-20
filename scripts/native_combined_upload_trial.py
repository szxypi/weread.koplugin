"""Independently gate a native upload-to-reading test in one profile."""
import base64,secrets,subprocess
from native_personal_upload_ui_trial import launch as upload_preview
from native_trial_pipe import Frames,reply,stop,write_initial
from personal_upload_trial import hash_value
from reading_epub_trial import check,validate_reading
from run_combined_upload_read import validate_gate
from run_native_personal_upload_ui import validate_stage as validate_upload
from secure_weread_session import COOKIE_NAMES,SessionStore
from synthetic_upload_epub import TEXT,build_reading
from verify_cb_progress import cb_id,cb_ids
from verify_cb_reading import BASE,CbReadingProbe,baseline_position
from verify_owner_reading import validate_cookies,validate_stage as validate_reading_stage
from verify_translation_preflight import save_refreshed_web_session
from verify_eink_renewal import validate_credentials
from verify_pdf_page_mapping import BodyText


def synthetic_source_verified(source):
    if not isinstance(source,str):return False
    parser=BodyText();parser.feed(source);text=' '.join(''.join(parser.parts).split())
    markers=[TEXT]+[f'Passage {index:02d} has an individual opening for safe position checks.' for index in range(1,49)]
    if any(text.count(value)!=1 for value in markers):return False
    positions=[text.find(value) for value in markers]
    return positions==sorted(positions) and len(set(positions))==len(positions)


def _cookies(web):
    return {cookie.name:cookie.value for cookie in web.cookies if cookie.name in COOKIE_NAMES
            and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}


def _prepare_read(target,owner,store):
    saved=store.load();web=None
    try:
        if saved['vid']!=owner:raise ValueError('combined/owner')
        web=CbReadingProbe();web.vid=owner
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();ids=cb_ids(web.request('shelf',BASE+'/web/shelf/sync'));web.verify_account()
        if target not in ids:raise ValueError('combined/target')
        save_refreshed_web_session(store,saved,web);web.samples.clear();web.close();web=None
        saved.clear();saved=store.load()
        if saved['vid']!=owner:raise ValueError('combined/owner')
        web=CbReadingProbe();web.vid=owner
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();sample=web.prepare(ids.index(target)+1,expected_book_id=target)[0];web.verify_account()
        if (sample['book_id']!=target or sample['source_format']!='web_xhtml' or not synthetic_source_verified(sample['source'])
                or set(web.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
                or not all(value is True for value in web.last_checks.values())):raise ValueError('combined/source')
        save_refreshed_web_session(store,saved,web);cookies=_cookies(web);latest=store.load()
        try:
            if latest['vid']!=owner or latest['cookies']!=cookies:raise ValueError('combined/session')
        finally:latest.clear()
        keys=('book_id','chapter_uid','source_format','source_text','source_raw_sha256','source_sample_offset','shelf_ids','shelf_books')
        reading={key:sample[key] for key in keys}
        reading.update(cb_reading=True,vid=owner,cookies=cookies,combined_upload_read=True)
        validate_gate(dict(seq=1,ok=True,payload=reading),target,owner,None)
        return reading,dict(sample['baseline'])
    finally:
        if web:web.samples.clear();web.close()
        saved.clear()


def _verify_after(target,owner,baseline,cookies,store):
    validate_cookies(cookies,owner);saved=store.load();web=CbReadingProbe();web.vid=owner;web.book_id=target;web.allowed={target}
    try:
        if saved['vid']!=owner:raise ValueError('combined/owner')
        for key,value in cookies.items():web.set_cookie(key,value)
        web.verify_account();value=web.request('progress_after',BASE+'/web/book/getProgress?bookId='+target)
        if baseline_position(value,target)!=baseline:raise ValueError('combined/progress')
        web.verify_account();save_refreshed_web_session(store,saved,web)
        return True
    finally:web.samples.clear();web.close();saved.clear()


def launch(plan,credentials,journal,target_receipt,probe,*,store=None):
    validate_reading(plan);validate_credentials(credentials)
    if credentials['vid']!=plan['owner'] or hash_value(credentials)!=plan['grant_sha256']:raise ValueError('combined/grant')
    if upload_preview(plan,credentials,armed=False,fixture='reading_epub')!={'preview':True}:raise ValueError('combined/preview')
    if not probe.grant_check(credentials) or not check(plan,credentials,probe.shelf(credentials)):raise ValueError('combined/changed')
    token=secrets.token_hex(16);payload=dict(credentials=credentials,name=plan['name'],shelf_books=plan['count'],rpc_token=token,
        permit_writes=True,fixture='reading_epub',body_base64=base64.b64encode(build_reading()).decode('ascii'),combined_upload=True)
    command=['docker','exec','-i','-w','/source','weread-validation','timeout','--signal=TERM','--kill-after=10','450',
        'python3','scripts/run_combined_upload_read.py','--koreader','/validation/runtime/lib/koreader',
        '--candidate','/validation/large-delay-ui-1264-v1/candidate.zip','--width','1264','--height','1680','--dpi','300']
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
                or not 1<=result['installed']['files']<=1000 or not isinstance(result['stages'],list) or len(result['stages'])!=2):
            raise ValueError('combined/result')
        upload=validate_upload(result['upload'],True)
        if upload['target']!=target:raise ValueError('combined/target')
        for mode,stage in zip(('live','reopen'),result['stages']):
            validate_reading_stage(stage,mode,cb_reading=True,combined_profile=True)
            if stage['result']!='PASS' or stage['shelf_books']!=reading['shelf_books']:raise ValueError('combined/reading')
        if any(result['stages'][0][key]!=result['stages'][1][key] for key in ('pages','shelf_books')):raise ValueError('combined/reading')
        _verify_after(target,credentials['vid'],baseline,result['cookies'],store)
        return dict(target=target,counts=dict(shelf=upload['native_gets'],credential=upload['credential_gets'],
            put=upload['puts'],notify=upload['notifies'],denied=upload['denied']))
    finally:
        payload.clear();stop(child)
