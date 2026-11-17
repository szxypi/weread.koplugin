"""Read-only inspection of an interrupted fixture/group experiment."""
from cloud_group_contract import digest, project
from personal_upload_trial import hash_value


def inspect(journal, fixture, grant, current, read_pair):
    """Return booleans only; never reconstruct or re-dispatch a request."""
    state, token=journal.read(); upload,_=fixture()
    if (not state or current() is not True or state['owner']!=grant['vid'] or state['grant_hash']!=digest(grant)
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
