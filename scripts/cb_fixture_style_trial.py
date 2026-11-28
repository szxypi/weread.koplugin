"""Four source-bound style operations on one new imported test highlight."""
from pathlib import Path
import tempfile

from annotation_experiment_model import digest
from cb_fixture_highlight_trial import prepare as prepare_highlight, validate_plan as validate_highlight
from highlight_trial_model import observe
from mark_style_trial_model import observe_change, style_body
from secure_mark_style_trial import MarkStyleTrialStore
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain

PROTOCOL = 'cb-synthetic-highlight-styles-v1'
SERVICE = 'org.codex.weread.cb-fixture-style-intent-v1'


def validate_plan(value):
    if not isinstance(value, dict) or value.get('protocol') != PROTOCOL:
        raise ValueError('cb_style/plan')
    validate_highlight(dict(value, protocol='cb-synthetic-highlight-create-remove-v1'))
    return value


class Intent(MarkStyleTrialStore):
    def __init__(self, backend=None, lock=None):
        if backend is None:
            backend = MacKeychain(service=SERVICE, account=ACCOUNT)
            path = Path(tempfile.gettempdir()) / ('codex-cb-fixture-style-' + ACCOUNT + '.lock')
            lock = lock or (lambda: project_lock(path))
        super().__init__(backend, lock, native=True)

    def validate_plan(self, value):
        return validate_plan(value)


def prepare(owner, book, attempt, sample, version, baseline):
    plan, body = prepare_highlight(owner, book, attempt, sample, version, baseline)
    return validate_plan(dict(plan, protocol=PROTOCOL)), body


def execute(plan, body, baseline, intent, owned, read, send):
    validate_plan(plan)
    if digest(body) != plan['request_sha256'] or digest(baseline) != plan['baseline_sha256']:
        raise ValueError('cb_style/changed')
    if not owned() or intent.read()[0] is not None or read() != baseline or read() != baseline or not owned():
        raise ValueError('cb_style/preflight')
    receipt = intent.reserve(plan)
    if not owned() or not intent.owns(receipt, 'create_pending'):
        raise ValueError('cb_style/ownership')
    send('create_pending', body, receipt)
    if not owned() or not intent.owns(receipt, 'create_pending'):
        raise ValueError('cb_style/ownership')
    current = read(); target = observe(baseline, current, body)
    row = current['marks']['updated'][target['id']]
    receipt = intent.advance(receipt, 'created', target=target)
    for pending, confirmed, style in (('straight_pending', 'straight', 0), ('wave_pending', 'wave', 2)):
        if not owned() or observe(baseline, read(), dict(body, style=row['style']), target=target) != target:
            raise ValueError('cb_style/changed')
        receipt = intent.advance(receipt, pending)
        if not owned() or not intent.owns(receipt, pending):
            raise ValueError('cb_style/ownership')
        send(pending, style_body(row, style), receipt)
        if not owned() or not intent.owns(receipt, pending):
            raise ValueError('cb_style/ownership')
        target, row = observe_change(baseline, read(), body, target, row, style)
        receipt = intent.advance(receipt, confirmed, target=target)
    if not owned() or observe(baseline, read(), dict(body, style=row['style']), target=target) != target:
        raise ValueError('cb_style/changed')
    receipt = intent.advance(receipt, 'delete_pending')
    if not owned() or not intent.owns(receipt, 'delete_pending'):
        raise ValueError('cb_style/ownership')
    send('delete_pending', {'bookmarkIds': [target['id']]}, receipt)
    if not owned() or not intent.owns(receipt, 'delete_pending'):
        raise ValueError('cb_style/ownership')
    observe(baseline, read(), dict(body, style=row['style']), deleted=True, target=target)
    receipt = intent.advance(receipt, 'verified'); intent.finish(receipt)
    return dict(result='PASS', writes=4, original_records_restored=True)
