#!/usr/bin/env python3
"""Read-only real CB dwell capture in KOReader; isolated immutable Keychain scope.

No account data writes, renewal, clock edits or historical dispatch. Source,
credentials and evidence remain in memory pipes and the dedicated Keychain.
"""
import argparse,json,re,resource,time
from urllib.parse import urlencode

from cb_native_time_capture_bundle import store as capture_store
from native_time_capture import validate
from native_time_capture_evidence import validate_evidence
from readtime_upload_model import integer
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest
from verify_cb_cloud_position import Web
from verify_cb_reading import readable_chapters
from verify_cb_source_currentness import descriptor
from cb_cloud_position import state
from verify_eink_login import BASE
from verify_native_time_capture import execute,full_point
from verify_native_txt_position import Native
from verify_readtime_upload import counters
from verify_translation_preflight import save_refreshed_web_session


class CaptureWeb(Web):
    def __init__(self):
        super().__init__();self.catalogs=[];self.shelf=None
    def request(self,stage,url,body=None,**options):
        value=super().request(stage,url,body,**options)
        if stage in ('catalog_before','catalog_after'):self.catalogs.append(value)
        if stage=='shelf':self.shelf=value
        return value


def snapshot(web,sample,native,grant):
    book=sample['book_id'];chapters=sample['chapters']
    if sample['source_format']!='web_xhtml' or len(web.catalogs)!=2 or web.shelf is None:raise ValueError('cb_capture/source')
    remote=web.progress[(book,'progress_before')]
    if not descriptor(sample,state(remote,book,chapters,'web')):raise ValueError('cb_capture/source')
    later=web.progress[(book,'progress_after')]
    if full_point(remote,book,'web')!=full_point(later,book,'web') or counters(remote,book)!=counters(later,book):
        raise ValueError('cb_capture/position')
    native_raw=native.request('cb_capture_progress',BASE+'/book/getProgress?'+urlencode({'bookId':book}),credentials=grant)
    info=native.request('cb_capture_info',BASE+'/book/info?'+urlencode({'bookId':book}),credentials=grant)
    shelf=native.request('cb_capture_shelf',BASE+'/shelf/sync',credentials=grant)
    version=info.get('bookVersion',info.get('version'))
    if info.get('bookId')!=book or not integer(version,1,2147483647):raise ValueError('cb_capture/version')
    versions=[]
    for raw in web.catalogs:
        record,observed=readable_chapters(raw,book)
        if observed!=chapters:raise ValueError('cb_capture/catalog')
        found=[node[key] for node in (record,record.get('book',{})) if isinstance(node,dict)
               for key in ('bookVersion','version') if key in node]
        if not found:raise ValueError('cb_capture/version')
        versions.extend(found)
    versions.extend(info[key] for key in ('bookVersion','version') if key in info)
    if any(not integer(item,1,2147483647) or item!=version for item in versions):raise ValueError('cb_capture/version')
    n=full_point(native_raw,book,'native');w=full_point(remote,book,'web')
    keys=('chapter_uid','chapter_idx','chapter_offset','raw_percent','summary')
    if any(n[key]!=w[key] for key in keys) or not n['summary']['present']:raise ValueError('cb_capture/position')
    summary=n['summary']['value']
    if (not 1<=len(summary)<=512 or len(summary.encode())>2048
            or any(ord(char)<32 and char not in '\t\r\n' for char in summary)):raise ValueError('cb_capture/summary')
    nc,wc=counters(native_raw,book),counters(remote,book)
    if nc!=wc:raise ValueError('cb_capture/counts')
    return dict(native=n,web=w,counts=nc,version=version,native_shelf=state_hash(shelf),web_shelf=state_hash(web.shelf),
                source=sample['source_raw_sha256'],catalog=digest({'book':book,'versions':versions,'chapters':chapters}))


def run(session,native_store,bundle,command,book_index,clock=time.time):
    report=dict(result='UNVERIFIED',phase='preflight',account_data_posts=0,authentication_posts=0,
                private_data_in_report=False,private_data_on_regular_disk=False)
    saved=grant=web=after=payload=output=None
    try:
        if bundle.read()!=(None,None):raise ValueError('cb_capture/already_saved')
        saved=session.load();grant=native_store.load(saved['vid']);web=CaptureWeb();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();samples=web.prepare(book_index)
        if len(samples)!=1:raise ValueError('cb_capture/selection')
        sample=samples[0];web.verify_account();book=sample['book_id'];api=Native(grant,book)
        before=snapshot(web,sample,api,grant)
        save_refreshed_web_session(session,saved,web)
        fresh=session.load()
        if fresh['vid']!=saved['vid']:raise ValueError('cb_capture/owner')
        saved.clear();saved=fresh
        fields=('book_id','chapter_uid','source_format','source_text','source_raw_sha256','source_sample_offset','shelf_ids','shelf_books')
        payload={key:sample[key] for key in fields}
        payload.update(cb_reading=True,vid=saved['vid'],cookies=saved['cookies'],native_time_capture={
            'device_sha256':digest(grant['deviceId']),'baseline_sha256':digest(before),'book_version':before['version']})
        report['phase']='native_capture';output=execute(payload,command)
        captured=validate(output['capture'],imported=True);validate_evidence(captured,output.get('sqlite_evidence'),imported=True)
        if (captured['owner']!=saved['vid'] or captured['book_id']!=book or captured['chapter_uid']!=sample['chapter_uid']
                or captured['device_sha256']!=digest(grant['deviceId']) or captured['baseline_sha256']!=digest(before)
                or captured['book_version']!=before['version'] or captured['raw_sha256']!=before['source']
                or not 0<=clock()-captured['ended_at']<=30):raise ValueError('cb_capture/binding')
        report['phase']='readback';after=CaptureWeb();after.vid=saved['vid']
        for key,value in output['cookies'].items():after.set_cookie(key,value)
        after.verify_account();after.allowed={book};after.request('shelf','https://weread.qq.com/web/shelf/sync')
        next_sample=after.inspect(book);after.verify_account()
        if snapshot(after,next_sample,api,grant)!=before:raise ValueError('cb_capture/changed')
        if save_refreshed_web_session(session,saved,after):
            fresh=session.load()
            if fresh['vid']!=saved['vid']:raise ValueError('cb_capture/owner')
            saved.clear();saved=fresh
        if native_store.load(saved['vid'])!=grant:raise ValueError('cb_capture/grant_changed')
        report['phase']='save';receipt=bundle.capture(captured,output['sqlite_evidence'])
        reread,again=bundle.read()
        if again!=receipt or reread!={'plan':captured,'evidence':output['sqlite_evidence']}:raise ValueError('cb_capture/save')
        report.update(result='CB_NATIVE_WINDOW_CAPTURED',phase='complete',seconds=captured['seconds'],rows=len(captured['rows']),
                      source_and_positions_unchanged=True,independent_snapshot=True,sqlite_evidence_saved=True,
                      profile_removed=output['profile_removed'],not_before_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(captured['not_before'])))
    except Exception as error:
        if isinstance(error,ValueError) and re.fullmatch('cb_capture/[a-z_]+',str(error)):report['reason']=str(error)
    finally:
        latest=after if after and getattr(after,'authenticated',False) else web if web and getattr(web,'authenticated',False) else None
        if latest and saved:
            try:save_refreshed_web_session(session,saved,latest)
            except Exception:report['result']='UNVERIFIED'
        for probe in (web,after):
            if probe:
                probe.samples.clear();probe.progress.clear();probe.catalogs.clear();probe.close()
        for value in (saved,grant,payload,output):
            if isinstance(value,dict):value.clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--capture',action='store_true')
    parser.add_argument('--book-index',type=int,choices=range(1,9),default=1)
    parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if (args.saved_session or args.capture or args.native_ui_command) and not (args.saved_session and args.capture and args.native_ui_command):
        parser.error('saved session, explicit capture and isolated native command are required together')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    try:report=run(SessionStore(),NativeSessionStore(),capture_store(),args.native_ui_command,args.book_index)
    except Exception:report=dict(result='UNVERIFIED',phase='setup',account_data_posts=0,authentication_posts=0)
    print(json.dumps(report));return int(report['result']!='CB_NATIVE_WINDOW_CAPTURED')


if __name__=='__main__':raise SystemExit(main())
