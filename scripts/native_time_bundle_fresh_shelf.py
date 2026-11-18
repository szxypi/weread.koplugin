"""Pure comparison against an independently observed fresh shelf baseline.

The caller must independently authenticate and bind every observation to the
same account, fixture and journal. This module performs no I/O and cannot
authorize a request or establish that historical time was credited.
"""
from cloud_group_contract import project
from native_time_bundle_evidence import FreshShelfEvidence
from txt_full_summary import digest
from verify_native_time_cross_day import check_group_fresh,without_fixture


def compare(evidence,bundle,grant,target,observations):
    if not isinstance(evidence,FreshShelfEvidence):raise ValueError('fresh_shelf/evidence')
    report,_snapshot,_months,_catalog,expected=evidence.for_bundle(bundle,grant)
    if not isinstance(observations,list) or len(observations)!=2:
        raise ValueError('fresh_shelf/observations')
    flags=('native_original_state_unchanged','web_original_state_unchanged')
    wanted=(report['previous_native_group_baseline_matches'],report['previous_web_group_baseline_matches'])
    for row in observations:
        if not isinstance(row,dict) or set(row)!={'native','web','group','original'}:
            raise ValueError('fresh_shelf/observations')
        check_group_fresh(row['group'],row['original'])
        if tuple(row['original'][key] for key in flags)!=wanted:
            raise ValueError('fresh_shelf/old_baseline_changed')
        for index,key in enumerate(('native','web')):
            without_fixture(row[key],target)
            if digest(project(row[key]))!=expected[index]:raise ValueError('fresh_shelf/changed')
    return {'result':'FRESH_SHELF_MATCH','compared_observations':2,
            'historical_accounting_verified':False,'dispatch_capability':False}
