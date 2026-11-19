"""Read-only inspection of an interrupted fixture/group experiment."""
from cloud_group_contract import digest, project
from cloud_group_nonempty_workflow import strip_fixture
from personal_upload_trial import hash_value


def _same_scope(state, token, grant, read_binding):
    return state['owner']==grant['vid'] and (state['grant_hash']==digest(grant)
        or read_binding is not None and read_binding.matches(state,token,grant))


def inspect(journal, fixture, grant, current, read_pair, read_binding=None):
    """Return booleans only; never reconstruct or re-dispatch a request."""
    state, token=journal.read(); upload,_=fixture()
    if (not state or current() is not True or not _same_scope(state,token,grant,read_binding)
            or upload['phase']!='imported' or state['target']!=upload['target'] or state['upload_attempt']!=upload['attempt']
            or state['upload_plan_hash']!=hash_value(upload['plan'])):
        raise ValueError('group_inspect/binding')
    samples=[]
    for _ in range(2):
        raw=read_pair()
        if not isinstance(raw,dict) or set(raw)!={'native','web'}: raise ValueError('group_inspect/read')
        samples.append(tuple(project(raw[k]) for k in ('native','web')))
    if samples[0]!=samples[1] or current() is not True or journal.read()!=(state,token):
        raise ValueError('group_inspect/changed')
    result=dict(result='INSPECTED',phase=state['phase'],dispatched=state['dispatched'],data_posts=0)
    for i,key in enumerate(('native','web')):
        observed=samples[1][i];matches=[row for row in observed['groups'].values() if row['name']==state['name']]
        if len(matches)>1: raise ValueError('group_inspect/ambiguous')
        row=matches[0] if matches else None
        result[key+'_fixture_present']=state['target'] in observed['members']
        result[key+'_group_present']=row is not None
        result[key+'_group_has_only_fixture']=row is not None and row['bookIds']==[state['target']]
        result[key+'_baseline_unchanged']=digest(observed)==state[key+'_before']
    return result


def inspect_original(old_journal, group_journal, fixture, grant, current, read_pair, old_guard, read_binding=None, removed_verified=None):
    """Compare each channel to the pre-upload shelf after removing only the fixture."""
    old_guard(False)
    old,old_token=old_journal.read(); group,group_token=group_journal.read(); upload,upload_token=fixture()
    if (not old or old['phase']!='closed_unverified' or old['owner']!=grant['vid']
            or not group or not _same_scope(group,group_token,grant,read_binding)
            or group['target']!=upload['target'] or group['upload_attempt']!=upload['attempt']
            or group['upload_plan_hash']!=hash_value(upload['plan']) or current() is not True):
        raise ValueError('group_inspect/binding')
    removed=removed_verified is not None and removed_verified(group,upload,grant['vid']) is True
    samples=[]
    for _ in range(2):
        raw=read_pair()
        if not isinstance(raw,dict) or set(raw)!={'native','web'}:raise ValueError('group_inspect/read')
        if removed:
            values=tuple(project(raw[key]) for key in ('native','web'))
            if any(upload['target'] in value['members'] or any(upload['target'] in row['bookIds'] for row in value['groups'].values())
                   for value in values):raise ValueError('group_inspect/changed')
            samples.append(values)
        else:samples.append(tuple(strip_fixture(raw[key],upload['target']) for key in ('native','web')))
    if (samples[0]!=samples[1] or current() is not True or old_journal.read()!=(old,old_token)
            or group_journal.read()!=(group,group_token) or fixture()!=(upload,upload_token)):
        raise ValueError('group_inspect/changed')
    result=dict(native_original_state_unchanged=digest(samples[1][0])==old['native_before'],
                web_original_state_unchanged=digest(samples[1][1])==old['web_before'],old_group_absent=True)
    if removed:result['fixture_cleanup_verified']=True
    return result
