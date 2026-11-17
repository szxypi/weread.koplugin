"""Read one exact newly uploaded synthetic EPUB through the packaged plugin."""
import contextlib,io,json
from secure_weread_session import SessionStore
from synthetic_upload_epub import TEXT
from verify_cb_progress import cb_id,cb_ids
from verify_cb_reading import BASE,CbReadingProbe
from verify_cb_native_reading import main as native_main
from verify_owner_reading import CB_SOURCE_REASONS,PHASES
from verify_translation_preflight import save_refreshed_web_session

COMMAND=['docker','exec','-i','-w','/source','-e','LD_LIBRARY_PATH=/validation/runtime/lib/koreader/libs','-e','SDL_VIDEODRIVER=dummy',
    'weread-validation','timeout','--signal=TERM','--kill-after=10','340','python3','scripts/run_owner_reading_probe.py',
    '--koreader','/validation/runtime/lib/koreader','--candidate','/validation/large-upload-runtimeko2-v1/candidate.zip',
    '--width','1264','--height','1680','--dpi','300','--cb-reading']


def verify(target,*,store=None,probe_factory=None,read_native=None,save_rotation=None,diagnostics=None):
    if not cb_id(target):raise ValueError('uploaded_reading/target')
    store=store or SessionStore();probe_factory=probe_factory or CbReadingProbe;read_native=read_native or native_main
    save_rotation=save_rotation or save_refreshed_web_session;saved=probe=None
    try:
        saved=store.load();probe=probe_factory();probe.vid=saved['vid']
        for key,value in saved['cookies'].items():probe.set_cookie(key,value)
        probe.verify_account();ids=cb_ids(probe.request('shelf',BASE+'/web/shelf/sync'));probe.verify_account()
        if target not in ids:raise ValueError('uploaded_reading/target_missing')
        rotated=save_rotation(store,saved,probe);index=ids.index(target)+1
        out=io.StringIO()
        with contextlib.redirect_stdout(out):
            code=read_native(['--saved-session','--book-index',str(index),'--lua-command',*COMMAND],
                expected_book_id=target,expected_source_text=TEXT)
        raw=out.getvalue()
        if len(raw)>1024*1024:raise ValueError('uploaded_reading/report')
        report=json.loads(raw)
        if diagnostics is not None and isinstance(report,dict):
            diagnostics['result']=report.get('result') if report.get('result') in ('CB_NATIVE_READING_VERIFIED','UNVERIFIED') else 'invalid'
            ui=report.get('ui')
            if isinstance(ui,dict):
                diagnostics['ui_result']=ui.get('result') if ui.get('result') in ('PASS','UNVERIFIED') else 'invalid'
                diagnostics['runner_error']=ui.get('runner_error') if ui.get('runner_error') in ('none','child_timeout','runner_exception','candidate_layout','input_limit','stage_unverified') else 'other'
                diagnostics['stages']=[]
                for row in ui.get('stages',[])[:2] if isinstance(ui.get('stages'),list) else []:
                    if not isinstance(row,dict):continue
                    safe={}
                    for key,allowed in (('result',('PASS','UNVERIFIED')),('phase',PHASES),('mode',('live','reopen')),('source_match_reason',CB_SOURCE_REASONS)):
                        if isinstance(row.get(key),str) and row[key] in allowed:safe[key]=row[key]
                    for key in ('failed_line','denied_kind','denied_route','denied_flags'):
                        if type(row.get(key)) is int and 0<=row[key]<=10000:safe[key]=row[key]
                    diagnostics['stages'].append(safe)
        if (code!=0 or not isinstance(report,dict) or report.get('result')!='CB_NATIVE_READING_VERIFIED'
                or any(report.get(k) is not True for k in ('same_owner_verified','source_text_matched','fresh_offline_process','cloud_position_unchanged'))
                or report.get('source_format')!='web_xhtml' or report.get('account_data_posts')!=0 or report.get('authentication_posts')!=0
                or report.get('private_data_on_regular_disk') is not False or report.get('screenshots')!=0):
            raise ValueError('uploaded_reading/unverified')
        return dict(result='UPLOADED_EPUB_NATIVE_READING_VERIFIED',target_bound=True,source_text_matched=True,
            cloud_position_unchanged=True,fresh_offline_process=True,account_data_posts=0,authentication_posts=0,
            verified_cookie_rotation_saved=rotated is True)
    finally:
        if probe:probe.samples.clear();probe.close()
        if saved:saved.clear()
