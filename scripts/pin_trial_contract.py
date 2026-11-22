"""One-use shelf-pin observation with durable stages and independent reads.

This module does not provide a network transport. Callers supply narrowly
scoped read and write functions. A rejected or ambiguous write is never retried.
"""
from copy import deepcopy
from finish_change_contract import flags
from native_shelf_trial import check
from secure_pin_trial import validate
from verify_finish_roundtrip import acknowledged
from verify_pin_preflight import progress_fingerprint

CHANNELS=('native','web','gateway')


def observe(plans,progress_sha256,current,read):
    current()
    snapshots,progress=read()
    if set(snapshots)!=set(CHANNELS) or progress_fingerprint(progress)!=progress_sha256:
        raise ValueError('pin/observation')
    return snapshots


def verify(snapshots,plans,present):
    target=plans['native']['membership']['book_id']
    result={}
    for name in CHANNELS:
        check(plans[name],snapshots[name],present)
        if present:
            row=flags(snapshots[name])[target]
            if any(item.get('reason')=='invalid' for item in row.values()):raise ValueError('pin/invalid_flag')
            result[name]=row
    return result


def run(plans,progress_sha256,skill_sha256,store,current,read,write):
    """Execute the single pre-bound sequence, stopping on any uncertainty."""
    if store.read()[0] is not None:raise ValueError('pin/already_used')
    for _ in range(2):verify(observe(plans,progress_sha256,current,read),plans,False)
    state,raw=store.reserve(deepcopy(plans),progress_sha256,skill_sha256)
    validate(state)
    target_flags=None;observations={};attempts=0
    for operation,pending,done,present in (
        ('add','add_pending','add_verified',True),('pin','pin_pending','pin_checked',True),
        ('unpin','unpin_pending','unpin_checked',True),('remove','remove_pending','restored',False)):
        # Verify immediately before every new write, including unrelated data and position.
        before=verify(observe(plans,progress_sha256,current,read),plans,operation!='add')
        if target_flags is not None:
            for channel in CHANNELS:
                for field in ('private','finished'):
                    if before[channel][field]!=target_flags[channel][field]:raise ValueError('pin/target_changed')
                if before[channel]['pinned']!=observations[operation_before[operation]][channel]:raise ValueError('pin/target_changed')
        _,raw=store.advance(raw,pending)
        attempts+=1
        response=write(operation)
        if not acknowledged(response):raise ValueError('pin/receipt_unknown')
        if operation=='add':_,raw=store.advance(raw,'add_acknowledged')
        pair=[]
        for _ in range(2):pair.append(verify(observe(plans,progress_sha256,current,read),plans,present))
        if pair[0]!=pair[1]:raise ValueError('pin/unstable')
        if present:
            after=pair[0]
            if target_flags is None:
                target_flags=deepcopy(after)
                if any(row['pinned']=={'value':True} for row in after.values()):raise ValueError('pin/already_pinned')
            else:
                for channel in CHANNELS:
                    for field in ('private','finished'):
                        if after[channel][field]!=target_flags[channel][field]:raise ValueError('pin/target_changed')
            observations[operation]={name:after[name]['pinned'] for name in CHANNELS}
        _,raw=store.advance(raw,done)
    visible=[name for name in CHANNELS if observations['pin'][name]=={'value':True}
             and observations['unpin'][name]=={'value':False}]
    return dict(result='PIN_OBSERVED_RESTORED' if visible else 'RESTORED_PIN_UNOBSERVABLE',
        writes_attempted=attempts,pin_states=observations,observable_channels=visible,
        original_members_flags_groups_and_progress_verified=True,intent_state='restored',no_automatic_replay=True)


operation_before={'pin':'add','unpin':'pin','remove':'unpin'}
