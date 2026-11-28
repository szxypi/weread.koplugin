"""One fixture-bound native pin/unpin, with independent host readbacks."""
from copy import deepcopy
import time

from imported_pin_preview_model import plans
from imported_pin_trial import request, sample
from native_cloud_pin_roundtrip import native_child
from personal_upload_trial import hash_value


def run(grant, target, before_raw, observe, current, records, metadata, command, mark_armed, *,
        child=native_child, sleep=time.sleep, mock_port=None):
    result={'result':'UNVERIFIED','phase':'preflight','native_posts_attempted':0,
            'independent_steps':0,'no_automatic_replay':True}
    try:
        if (any(records[name].read()[0] is not None for name in ('pin','restore'))
                or not isinstance(metadata,dict) or metadata.get('bookId')!=target):
            raise ValueError('native_imported_pin/scope')
        before=sample(lambda _identity:deepcopy(before_raw),current,target)
        if (before!=sample(observe,current,target) or before['native_pin']!={'reason':'missing'}
                or before['web_pin']!={'reason':'missing'}):raise ValueError('native_imported_pin/baseline')
        mark,restore=plans(before_raw['native'],before_raw['progress'],target)
        payload={'credentials':grant,'book_id':target,'expected_metadata':metadata,
                 'shelf_books':len(before_raw['native']['books']),'mark':mark,'restore':restore}
        if mock_port is not None:
            if (type(mock_port) is not int or not 1<=mock_port<=65535 or target!='CB_SyntheticResume'
                    or grant!={'vid':'900000','accessToken':'mock-native-access','refreshToken':'mock-native-refresh',
                               'deviceId':'eink334691225'+'1'*19}):raise ValueError('native_imported_pin/mock')
            payload['mock_port']=mock_port
        result['phase']='dry_run'
        dry,_=child(payload,command,armed=False,on_step=lambda _step:None)
        if sample(observe,current,target)!=before:raise ValueError('native_imported_pin/changed')
        def intent_plan(kind,baseline):
            return {'selection':{'owner':grant['vid'],'book_id':target,'grant_hash':hash_value(grant)},
                    'record':{'kind':kind},'body':request(target,kind=='pin'),
                    'baseline':{'snapshot_hash':hash_value(baseline),'native_hash':hash_value(baseline['native']),
                                'web_hash':hash_value(baseline['web']),'progress_hash':baseline['progress_hash']}}
        pinned=deepcopy(before);pinned['native_pin']=pinned['web_pin']={'value':True}
        pin_receipt=records['pin'].claim(intent_plan('pin',before));restore_receipt=None
        if sample(observe,current,target)!=before:raise ValueError('native_imported_pin/changed')
        def stable(expected):
            for attempt in range(4):
                value=sample(observe,current,target)
                if any(value[key]!=before[key] for key in ('native','web','progress_hash')):
                    raise ValueError('native_imported_pin/changed')
                if value==expected and sample(observe,current,target)==expected:return
                if attempt<3:sleep(.5*(attempt+1))
            raise ValueError('native_imported_pin/unconfirmed')
        def step(sequence):
            nonlocal pin_receipt,restore_receipt
            if sequence==1:
                stable(pinned)
                pin_receipt=records['pin'].advance(pin_receipt,'acknowledged')
                pin_receipt=records['pin'].advance(pin_receipt,'verified')
                restore_receipt=records['restore'].claim(intent_plan('restore',pinned))
                stable(pinned)
                result['phase']='restore_claimed'
            elif sequence==2 and restore_receipt is not None:
                stable(before)
                restore_receipt=records['restore'].advance(restore_receipt,'acknowledged')
                restore_receipt=records['restore'].advance(restore_receipt,'verified')
                result['phase']='restore_verified'
            else:raise ValueError('native_imported_pin/order')
            result['independent_steps']=sequence
        result['phase']='pin_claimed';mark_armed();result['native_posts_attempted']=None
        ui,steps=child(payload,command,armed=True,on_step=step)
        if steps!=2 or result['independent_steps']!=2:raise ValueError('native_imported_pin/incomplete')
        stable(before)
        result.update(result='PASS',phase='restored',native_posts_attempted=2,dry_run=dry,native_ui=ui)
    except (Exception,KeyboardInterrupt):
        result['reason']='native_imported_pin/unconfirmed'
    return result
