"""Coordinate an isolated upload and group experiment without a CLI.

Injected collaborators must enforce their own network scopes. No private
shelf snapshots, identifiers, or authorization values are put in the report.
"""
from copy import deepcopy

from cloud_group_contract import project
from cloud_group_fixture import binding
from cloud_group_nonempty_trial import Trial
from cloud_group_trial import _cross_channel
from verify_cb_progress import cb_id
from verify_synthetic_epub_upload import run as upload
from web_shelf_contract import identity


def strip_fixture(source, target):
    """Project the full shelf excluding exactly the temporary book."""
    if not cb_id(target): raise ValueError('group_workflow/target')
    project(source)  # validate before filtering, including duplicate IDs
    value = deepcopy(source)
    matches = [row for row in value['books'] if identity(row['bookId']) == target]
    if len(matches) != 1: raise ValueError('group_workflow/target')
    value['books'] = [row for row in value['books'] if identity(row['bookId']) != target]
    for group in value.get('archive', []):
        group['bookIds'] = [item for item in group['bookIds'] if identity(item) != target]
    return project(value)


def execute(*, upload_probe, upload_journal, group_journal, target_receipt, grant, current,
            old_guard, read_pair, post, pending, read_content, apply=False, sleep=None, now=None):
    report = dict(result='UNVERIFIED', phase='preflight', group_posts=0, fixture_cleanup_posts=0)
    try:
        if (upload_journal.read()[0] is not None or group_journal.read()[0] is not None
                or target_receipt.backend.load() is not None or pending() is not True or current() is not True):
            raise ValueError('group_workflow/scope')
        baseline = old_guard(True)
        if (not isinstance(baseline, tuple) or len(baseline) != 2 or not _cross_channel(*baseline)
                or not baseline[0]['albums']['present']
                or any('albumIds' not in row for row in baseline[0]['groups'].values())):
            raise ValueError('group_workflow/baseline')
        bound = lambda: binding(upload_journal, target_receipt.backend)
        def gate(_journal, _receipt, _plan, target):
            if pending() is not True or current() is not True: return False
            trial = Trial(group_journal, bound, read_pair, post, current, **({'sleep':sleep} if sleep else {}))
            result = trial.run(); report['group_posts'] = result['data_posts']; report['group_phase'] = result['phase']
            if result['result'] != 'PASS': return False
            group, _ = group_journal.read()
            state, _ = bound()
            if not group or group['phase'] != 'restored' or group['target'] != state['target'] or target != state['target']:
                return False
            if pending() is not True or current() is not True: return False
            old_guard(False)
            first = read_pair(); second = read_pair()
            if set(first) != {'native','web'} or set(second) != {'native','web'}: return False
            if tuple(project(first[k]) for k in ('native','web')) != tuple(project(second[k]) for k in ('native','web')): return False
            return tuple(strip_fixture(second[k], target) for k in ('native','web')) == baseline
        options = dict(apply=apply, notify_receipt=target_receipt.record, cleanup_gate=gate)
        if sleep is not None: options['sleep']=sleep
        if now is not None: options['now']=now
        result = upload(upload_probe, upload_journal, grant, lambda value:current() is True and value == grant,
                        read_content, **options)
        report.update(phase=result['phase'], fixture_cleanup_posts=result['cleanup_posts'], upload_result=result['result'])
        if not apply and result['result'] == 'READ_ONLY_PREVIEW':
            report['result']='READ_ONLY_PREVIEW'
        elif result['phase'] == 'restored':
            after = old_guard(True)
            if after == baseline and pending() is True and current() is True:
                report.update(result='PASS', phase='restored', full_shelf_restored=True)
    except Exception:
        pass
    return report
