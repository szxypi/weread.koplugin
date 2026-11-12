#!/usr/bin/env python3
"""Read-only native/Web TXT source agreement, no write or renewal path."""
import argparse
from datetime import datetime,timezone
import json
import resource
from urllib.parse import urlencode
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from verify_txt_cloud_position import Probe as Source
from verify_eink_login import NativeProbe,BASE
from verify_reader_progress import project,find_node
from verify_position_roundtrip import same_position
from verify_translation_preflight import save_refreshed_web_session
from readtime_upload_model import integer,guest_token


class Native(NativeProbe):
    def __init__(self,credentials,identity,opener=None):
        super().__init__(opener);self.credentials=credentials;self.identity=identity;self.reads=0
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        allowed={BASE+'/config?token=1',BASE+'/feature?synckey=0',BASE+'/shelf/sync'}|{
            BASE+'/book/'+route+'?'+urlencode(dict(bookId=self.identity)) for route in ('getProgress','info')}
        if body is not None or credentials!=self.credentials or url not in allowed or self.reads>=12:raise ValueError('native_txt/read_scope')
        self.reads+=1;return super().request(stage,url,credentials=credentials,timeout=timeout)


def compare(source,native,identity):
    point=project(native,identity,'native');baseline=source['baseline'];node=find_node(native,identity)
    if not same_position(point,baseline) or node.get('summary')!=baseline['summary']:raise ValueError('native_txt/position')
    counts={key:node.get(key) for key in ('readingTime','recordReadingTime','ttsTime')}
    if any(not integer(value,0,2**53-1) for value in counts.values()):raise ValueError('native_txt/counters')
    return point,counts


def inspect(web,native,credentials,plan,report=None):
    report=report if report is not None else {}
    identity=web.book_id;progress_url=BASE+'/book/getProgress?'+urlencode(dict(bookId=identity))
    first=native.request('native_txt_progress',progress_url,credentials=credentials);point,counts=compare(plan,first,identity)
    metadata=native.request('native_txt_metadata',BASE+'/book/info?'+urlencode(dict(bookId=identity)),credentials=credentials)
    report.update(same_point_and_complete_summary=True,time_counters_observed=True)
    native_version=metadata.get('bookVersion',metadata.get('version'))
    record=web.sample['record'];info=record.get('book',{})
    versions=[item[key] for item in (record,info) for key in ('bookVersion','version') if key in item]
    def kind(value):
        return 'zero' if type(value) is int and value==0 else 'positive' if integer(value,1,2147483647) else 'missing' if value is None else 'invalid'
    report['version_field_kinds']={
        'native_bookVersion':kind(metadata.get('bookVersion')),'native_version':kind(metadata.get('version')),
        'catalog_bookVersion':kind(record.get('bookVersion')),'catalog_version':kind(record.get('version')),
        'book_bookVersion':kind(info.get('bookVersion')),'book_version':kind(info.get('version'))}
    report['selected_versions_equal']=bool(versions) and all(type(version) is int and version==native_version for version in versions)
    if str(metadata.get('bookId'))!=identity or not integer(native_version,0,2147483647):raise ValueError('native_txt/version')
    if any(not integer(metadata[key],0,2147483647) or metadata[key]!=native_version for key in ('bookVersion','version') if key in metadata):raise ValueError('native_txt/version')
    matched=integer(native_version,1,2147483647) and bool(versions) and all(integer(version,1,2147483647) and version==native_version for version in versions)
    unversioned=native_version==0 and not versions
    if not matched and not unversioned:raise ValueError('native_txt/version')
    report.update(book_version_matched=matched,unversioned_native_zero=unversioned)
    config=native.request('native_txt_config',BASE+'/config?token=1',credentials=credentials)
    token=config.get('token')
    if not isinstance(token,str) or not 1<=len(token)<=4096:raise ValueError('native_txt/token')
    guest,kind=guest_token(native.request('native_txt_feature',BASE+'/feature?synckey=0',credentials=credentials))
    metadata_again=native.request('native_txt_metadata_again',BASE+'/book/info?'+urlencode(dict(bookId=identity)),credentials=credentials)
    if any((key in metadata_again)!=(key in metadata) or type(metadata_again.get(key)) is not type(metadata.get(key))
           or metadata_again.get(key)!=metadata.get(key) for key in ('bookId','bookVersion','version')):raise ValueError('native_txt/version')
    later=native.request('native_txt_progress_again',progress_url,credentials=credentials)
    second,counts_after=compare(plan,later,identity)
    if counts!=counts_after:raise ValueError('native_txt/counters_changed')
    return dict(point=point,counts=counts,version=native_version,version_matched=matched,guest=guest,guest_kind=kind,token=token,native_progress=first)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,
        private_data_on_regular_disk=False,production_upload_enabled=False)
    saved=credentials=web=native=None
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            store=SessionStore();saved=store.load();credentials=NativeSessionStore().load(saved['vid']);web=Source();web.vid=saved['vid']
            for k,v in saved['cookies'].items():web.set_cookie(k,v)
            web.verify_account()
            if not web.find_sample(limit=16):raise ValueError('native_txt/no_sample')
            plan=web.inspect_plan();native=Native(credentials,web.book_id);value=inspect(web,native,credentials,plan,report)
            if web.inspect_plan()['baseline']!=plan['baseline']:raise ValueError('native_txt/web_changed')
            report.update(result='NATIVE_TXT_READ_ONLY_SNAPSHOT_VERIFIED',same_point_and_complete_summary=True,
                summary_scalars=len(plan['baseline']['summary']),time_counters_stable=True,config_token_read=True,guest_token_source=value['guest_kind'],
                native_chapter_progress_provided='chapterProgress' in find_node(value['native_progress'],web.book_id),
                raw_percent_integral=float(value['point']['raw_percent']).is_integer(),native_write_semantics_verified=False)
    except Exception as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and str(error) in {'native_txt/version','native_txt/position','native_txt/counters','native_txt/token','native_txt/counters_changed','native_txt/web_changed','native_txt/no_sample'}:report['reason']=str(error)
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(store,saved,web)
                except Exception:report['result']='UNVERIFIED'
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']];web.sample=None;web.close()
        if native:report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in native.report['stages']]
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
