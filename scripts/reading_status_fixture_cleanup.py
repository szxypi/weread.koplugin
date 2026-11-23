"""One exact fixture removal after independently verified status recovery."""
import time

from personal_upload_trial import hash_value
from reading_status_fixture_trial import request
from verify_personal_upload_trial import acknowledged


def run(upload, mark, restore, cleanup, bound, current, pending, observe, remove, after, *, apply=False, sleep=time.sleep):
    report = dict(result='UNVERIFIED', phase='preflight', cleanup_posts=0, cleanup_acknowledged=False,
                  restored_shelf_observed=False)
    try:
        state, receipt = bound()
        first_mark, _ = mark.read()
        first_restore, _ = restore.read()
        if (current() is not True or pending() is not True or cleanup.read()[0] is not None
                or not first_mark or first_mark['phase'] != 'claimed'
                or not first_restore or first_restore['phase'] != 'claimed'):
            raise ValueError('reading_cleanup/scope')
        marked, restored = first_mark['plan'], first_restore['plan']
        expected = dict(owner=state['plan']['owner'], target=state['target'], upload_attempt=state['attempt'],
                        upload_plan_hash=hash_value(state['plan']), grant_hash=state['plan']['grant_sha256'])
        if (marked['selection'] != expected or restored['selection'] != expected
                or marked['record'] != {'kind': 'mark'} or restored['record'] != {'kind': 'restore'}
                or marked['body'] != request(state['target'], False)
                or restored['body'] != request(state['target'], True)):
            raise ValueError('reading_cleanup/binding')
        one, two = observe(state), observe(state)
        if (one != two or one['progress']['flag'] != 0
                or hash_value(one) != marked['baseline']['snapshot_hash']
                or bound()[0] != state or current() is not True or pending() is not True):
            raise ValueError('reading_cleanup/baseline')
        if not apply:
            report.update(result='READ_ONLY_PREVIEW', phase='preview', restored_state_verified=True)
            return report
        body = {'bookIds': [state['target']], 'albumIds': [], 'archiveIds': []}
        plan = dict(selection=expected, record={'kind': 'cleanup'}, body=body,
                    baseline={'snapshot_hash': hash_value(one)})
        # A crash after this durable claim cannot authorize another cleanup.
        cleanup.claim(plan)
        if bound()[0] != state or current() is not True or pending() is not True:
            raise ValueError('reading_cleanup/changed')
        receipt = upload.advance(receipt, 'cleanup_pending')
        report['phase'] = 'cleanup_pending'
        report['cleanup_posts'] = 1
        try:
            response = remove(receipt)
        except Exception:
            response = None
        report['cleanup_acknowledged'] = acknowledged(response)
        for attempt in range(3 if report['cleanup_acknowledged'] else 1):
            if attempt:
                sleep(.5 * attempt)
            try:
                verified = after(state) and after(state) and current() is True
            except Exception:
                verified = False
            if verified:
                report['restored_shelf_observed'] = True
                break
        if report['cleanup_acknowledged'] and report['restored_shelf_observed']:
            upload.advance(receipt, 'restored')
            report.update(result='CLEANED', phase='restored')
        elif report['restored_shelf_observed']:
            report.update(result='CLEANED_ACK_UNKNOWN', phase='cleanup_unverified')
    except Exception:
        pass
    return report
