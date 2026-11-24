"""Bounded synthetic import/removal with private, field-level snapshot hashes."""
import json
import re
from cloud_group_contract import project
from cloud_group_fixture import binding
from cloud_group_nonempty_workflow import strip_fixture
from cloud_group_trial import _cross_channel
from personal_upload_trial import hash_value, projection as upload_projection
from secure_weread_session import SessionStore
from verify_cloud_group_trial import no_other_pending
from verify_eink_login import BASE, NativeProbe
from verify_personal_upload_trial import Probe as UploadProbe
from verify_cb_progress import cb_id
from verify_synthetic_epub_upload import read_source, run as upload

CHANNELS=('native','web')
COMPONENTS=('members','flags','groups','albums')
KNOWN_FIELDS=('archiveId','albumId','bookIds','albumIds','name','title','isTop','updateTime','createTime',
              'sort','sortTime','readUpdateTime','bookCount','albumCount','seq')
FIELDS=KNOWN_FIELDS+('other',)


def field_hashes(snapshot,kind,*,version=2):
    if version not in (1,2):raise ValueError('import_cleanup/version')
    known=FIELDS if version==1 else KNOWN_FIELDS
    if kind=='groups':
        rows=snapshot['groups']
        def extract(field):
            return {identity:({key:value for key,value in row.items() if key not in known} if field=='other'
                              else {'present':field in row,'value':row.get(field)}) for identity,row in rows.items()}
    elif kind=='albums':
        album=snapshot['albums']
        def extract(field):
            if not album['present']:return {'present':False}
            rows=album['value']
            return {'present':True,'rows':[({key:value for key,value in row.items() if key not in known} if field=='other'
                    else {'present':field in row,'value':row.get(field)}) if isinstance(row,dict)
                    else {'non_object':row if version==1 or field=='other' else True} for row in rows]}
    else:raise ValueError('import_cleanup/kind')
    return {field:hash_value(extract(field)) for field in FIELDS}


def fingerprints(snapshots,*,version=2):
    result={}
    for channel in CHANNELS:
        result[channel]=hash_value(snapshots[channel])
        for field in COMPONENTS:result[channel+'_'+field]=hash_value(snapshots[channel][field])
        for kind in ('groups','albums'):
            for field,digest in field_hashes(snapshots[channel],kind,version=version).items():result[channel+'_'+kind+'_'+field]=digest
    return result


def compare(snapshots,baseline,*,version=2):
    actual=fingerprints(snapshots,version=version)
    if set(actual)!=set(baseline):raise ValueError('import_cleanup/baseline')
    return {channel:{'full':actual[channel]==baseline[channel],
                     'components':{field:actual[channel+'_'+field]==baseline[channel+'_'+field] for field in COMPONENTS},
                     'group_fields':{field:actual[channel+'_groups_'+field]==baseline[channel+'_groups_'+field] for field in FIELDS},
                     'album_fields':{field:actual[channel+'_albums_'+field]==baseline[channel+'_albums_'+field] for field in FIELDS}}
            for channel in CHANNELS}


def _binding_value(saved,grant,state,receipt,baseline):
    if grant.get('vid')!=saved['vid'] or not isinstance(grant.get('deviceId'),str):raise ValueError('import_cleanup/binding')
    return {'schema':1,'owner':saved['vid'],'device_hash':hash_value(grant['deviceId']),
            'upload_hash':hash_value(state),'receipt_hash':hash_value(receipt),'baseline_hash':hash_value(baseline)}


def validate_records(saved,grant,journal,receipt,baseline_record,protected,binding_backend=None):
    state,_=journal.read();raw=receipt.backend.load();baseline,_=baseline_record.read()
    stored=json.loads(raw) if isinstance(raw,bytes) and len(raw)<=8192 else None
    empty={'members':[],'flags':'','groups':{},'albums':{'present':False}}
    expected_keys=set(fingerprints({key:empty for key in CHANNELS}))
    if (not state or state['phase']!='restored' or not cb_id(state['target']) or state['target'] in protected
            or not isinstance(stored,dict) or set(stored)!={'schema','owner','attempt','target','plan_sha256'}
            or type(stored['schema']) is not int or stored['schema']!=1 or stored['owner']!=saved['vid'] or stored['attempt']!=state['attempt']
            or stored['target']!=state['target'] or stored['plan_sha256']!=hash_value(state['plan'])
            or state['plan']['owner']!=saved['vid'] or not baseline or baseline['phase']!='claimed'
            or set(baseline['plan'])!={'selection','record','body','baseline'}
            or baseline['plan']['selection']!={'owner':saved['vid'],'grant_hash':state['plan']['grant_sha256']}
            or baseline['plan']['record'] not in ({'kind':'import_cleanup_baseline'},{'kind':'import_cleanup_baseline_v2'})
            or baseline['plan']['body']!={}
            or not isinstance(baseline['plan']['baseline'],dict) or set(baseline['plan']['baseline'])!=expected_keys
            or any(not isinstance(v,str) or not re.fullmatch(r'[a-f0-9]{64}',v) for v in baseline['plan']['baseline'].values())):
        raise ValueError('import_cleanup/records')
    if state['plan']['grant_sha256']!=hash_value(grant):
        raw_binding=binding_backend.load() if binding_backend else None
        try:value=json.loads(raw_binding) if isinstance(raw_binding,bytes) and len(raw_binding)<=2048 else None
        except (ValueError,UnicodeError):value=None
        if value!=_binding_value(saved,grant,state,stored,baseline):raise ValueError('import_cleanup/binding')
    return state,stored,baseline


def bind_audit(saved,grant,journal,receipt,baseline_record,protected,binding_backend):
    state,stored,baseline=validate_records(saved,grant,journal,receipt,baseline_record,protected)
    value=_binding_value(saved,grant,state,stored,baseline)
    encoded=json.dumps(value,sort_keys=True,separators=(',',':')).encode()
    previous=binding_backend.load()
    if previous is not None and previous!=encoded:raise ValueError('import_cleanup/binding')
    if previous is None:binding_backend.save(encoded)
    if binding_backend.load()!=encoded:raise ValueError('import_cleanup/binding')


def audit(saved,native_store,web,journal,receipt,baseline_record,protected,*,native=None,pending=no_other_pending,binding_backend=None):
    grant=native_store.load(saved['vid']);session=SessionStore();native=native or NativeProbe()
    try:
        state,_stored,baseline=validate_records(saved,grant,journal,receipt,baseline_record,protected,binding_backend)
        def read():
            if session.load()!=saved or native_store.load(saved['vid'])!=grant or pending() is not True:
                raise ValueError('import_cleanup/session')
            pair={'native':native.request('shelf',BASE+'/shelf/sync',credentials=grant),
                  'web':web.request('shelf','https://weread.qq.com/web/shelf/sync')}
            snapshots={key:project(value) for key,value in pair.items()}
            if any(state['target'] in snapshots[key]['members'] for key in CHANNELS) or not _cross_channel(snapshots['native'],snapshots['web']):
                raise ValueError('import_cleanup/shelf')
            return snapshots,{key:upload_projection(value) for key,value in pair.items()}
        first=read();second=read()
        if first!=second:raise ValueError('import_cleanup/unstable')
        snapshots,core=second;version=1 if baseline['plan']['record']['kind']=='import_cleanup_baseline' else 2
        comparisons=compare(snapshots,baseline['plan']['baseline'],version=version)
        fields=('count','members_sha256','flags_sha256','groups_sha256')
        return {'result':'READ_ONLY_RESTORED' if all(comparisons[key]['full'] for key in CHANNELS) else 'READ_ONLY_SNAPSHOT_CHANGED',
                'account_data_writes':0,'fixture_absent_both_channels':True,'two_stable_readbacks':True,
                'field_hash_version':version,
                'native_web_members_and_groups_match':True,'comparisons':comparisons,
                'native_original_core_matches':{key:core['native'][key]==state['plan'][key] for key in fields},
                'native_web_core_matches':{key:core['native'][key]==core['web'][key] for key in fields}}
    finally:grant.clear()


def execute(saved,native_store,web,journal,receipt,baseline_record,protected,*,apply=False,
            native=None,upload_probe=None,uploader=upload,content_reader=read_source,pending=no_other_pending):
    report={'result':'UNVERIFIED','phase':'preflight','existing_book_writes':0,'pin_posts_attempted':0,
            'fixture_notify_posts':0,'fixture_cleanup_posts':0,'authentication_posts':0,'no_automatic_replay':True}
    grant=native_store.load(saved['vid']);session=SessionStore();native=native or NativeProbe()
    def current():return session.load()==saved and native_store.load(saved['vid'])==grant and pending() is True
    def pair():
        if not current():raise ValueError('import_cleanup/session')
        return {'native':native.request('shelf',BASE+'/shelf/sync',credentials=grant),
                'web':web.request('shelf','https://weread.qq.com/web/shelf/sync')}
    try:
        if (journal.read()[0] is not None or receipt.backend.load() is not None or baseline_record.read()[0] is not None
                or not current()):raise ValueError('import_cleanup/consumed')
        initial=pair();original={key:project(value) for key,value in initial.items()}
        if not _cross_channel(original['native'],original['web']) or original!={key:project(value) for key,value in pair().items()}:
            raise ValueError('import_cleanup/unstable')
        baseline=fingerprints(original)
        if apply:
            baseline_record.claim({'selection':{'owner':grant['vid'],'grant_hash':hash_value(grant)},
                'record':{'kind':'import_cleanup_baseline_v2'},'body':{},'baseline':baseline})
        gate_result={'passed':False};probe=upload_probe or UploadProbe(journal,lambda value:current() and value==grant)
        def gate(_journal,_token,_plan,target):
            bound,_=binding(journal,receipt.backend)
            if (bound['target']!=target or target in protected or bound['plan']['owner']!=grant['vid']
                    or bound['plan']['grant_sha256']!=hash_value(grant) or not current()):return False
            for _ in range(2):
                fresh,_=binding(journal,receipt.backend);shelves=pair()
                if fresh!=bound or not _cross_channel(project(shelves['native']),project(shelves['web'])):return False
                if any(strip_fixture(shelves[key],target)!=original[key] for key in CHANNELS):return False
            gate_result['passed']=True;return current()
        result=uploader(probe,journal,grant,lambda value:current() and value==grant,
            lambda target:content_reader(saved,target) is True,apply=apply,notify_receipt=receipt.record,cleanup_gate=gate)
        report.update(phase=result['phase'],upload_result=result['result'],fixture_notify_posts=result['notify_posts'],
                      fixture_cleanup_posts=result['cleanup_posts'],fixture_source_verified=result['source_verified'],
                      precleanup_full_shelf_matches=gate_result['passed'])
        if not apply and result['result']=='READ_ONLY_PREVIEW':report['result']='READ_ONLY_PREVIEW'
        elif result['phase']=='restored':
            state,_=journal.read();fresh=pair();again=pair()
            final={key:project(value) for key,value in fresh.items()};repeated={key:project(value) for key,value in again.items()}
            if final!=repeated or any(state['target'] in final[key]['members'] for key in CHANNELS):
                raise ValueError('import_cleanup/final')
            comparisons=compare(final,baseline);cores={key:upload_projection(fresh[key]) for key in CHANNELS}
            fields=('count','members_sha256','flags_sha256','groups_sha256')
            report.update(two_stable_readbacks=True,fixture_absent_both_channels=True,
                field_hash_version=2,native_web_members_and_groups_match=_cross_channel(final['native'],final['web']),comparisons=comparisons,
                native_original_core_matches={key:cores['native'][key]==state['plan'][key] for key in fields},
                native_web_core_matches={key:cores['native'][key]==cores['web'][key] for key in fields})
            report['result']='RESTORED_FULL' if all(comparisons[key]['full'] for key in CHANNELS) else 'RESTORED_SNAPSHOT_CHANGED'
    except Exception:
        report['reason']='import_cleanup/unavailable'
    finally:grant.clear()
    return report
