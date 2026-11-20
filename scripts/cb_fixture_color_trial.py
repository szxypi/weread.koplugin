"""Complete palette on fresh source-bound imported highlights only."""
from pathlib import Path
import tempfile

from annotation_experiment_model import digest
from cb_fixture_highlight_trial import prepare as prepare_highlight, validate_plan as validate_highlight
from highlight_trial_model import observe
from mark_color_model import color_body, observe_color
from mark_style_trial_model import target_valid
from secure_mark_color import MarkColorStore
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain

PROTOCOL = 'cb-synthetic-highlight-palette-v1'
SERVICE = 'org.codex.weread.cb-fixture-palette-intent-v1'
STEPS = (('create', 0),) + tuple(('color', c) for c in (1, 2, 3, 4, 5, 0)) + (('delete', None),) + tuple(
    step for c in range(1, 6) for step in (('create', c), ('delete', None)))


def validate_plan(value):
    if (not isinstance(value, dict) or set(value) != {'protocol', 'highlight', 'creation_hashes'}
            or value['protocol'] != PROTOCOL or not isinstance(value['creation_hashes'], list)
            or len(value['creation_hashes']) != 6
            or any(not isinstance(v, str) or len(v) != 64 or any(c not in '0123456789abcdef' for c in v)
                   for v in value['creation_hashes']) or len(set(value['creation_hashes'])) != 6): raise ValueError('cb_color/plan')
    validate_highlight(value['highlight'])
    if value['highlight']['request_sha256'] != value['creation_hashes'][0]: raise ValueError('cb_color/plan')
    return value


def dispatch_hash(plan, step, target):
    validate_plan(plan)
    if type(step) is not int or not 0 <= step < len(STEPS): raise ValueError('cb_color/step')
    operation, color = STEPS[step]
    if operation == 'create':
        if target is not None: raise ValueError('cb_color/target')
        return plan['creation_hashes'][color]
    if not target_valid(target): raise ValueError('cb_color/target')
    body = {'bookmarkIds': [target['id']]} if operation == 'delete' else dict(bookmarkId=target['id'], style=1, colorStyle=color)
    return digest(body)


class Intent(MarkColorStore):
    steps = STEPS
    validate_plan = staticmethod(validate_plan)
    dispatch_hash = staticmethod(dispatch_hash)
    def __init__(self, backend=None, lock=None):
        if backend is None:
            backend = MacKeychain(service=SERVICE, account=ACCOUNT)
            path = Path(tempfile.gettempdir()) / ('codex-cb-fixture-palette-' + ACCOUNT + '.lock')
            lock = lock or (lambda: project_lock(path))
        super().__init__(backend, lock)


def prepare(owner, book, attempt, sample, version, baseline):
    highlight, body = prepare_highlight(owner, book, attempt, sample, version, baseline)
    plan = dict(protocol=PROTOCOL, highlight=highlight,
                creation_hashes=[digest(dict(body, colorStyle=c)) for c in range(6)])
    return validate_plan(plan), body


def execute(plan, body, baseline, intent, owned, read, send):
    validate_plan(plan)
    if (digest(body) != plan['highlight']['request_sha256'] or digest(baseline) != plan['highlight']['baseline_sha256']
            or not owned() or intent.read()[0] is not None or read() != baseline or read() != baseline or not owned()):
        raise ValueError('cb_color/preflight')
    receipt = intent.reserve(plan); target = row = None
    for index, (operation, color) in enumerate(STEPS):
        if not owned(): raise ValueError('cb_color/ownership')
        current = read()
        observe(baseline, current, dict(body, colorStyle=row['colorStyle']) if row else body,
                target=target, deleted=target is None)
        if operation == 'create': request = dict(body, colorStyle=color)
        elif operation == 'color': request = color_body(row, color)
        else: request = {'bookmarkIds': [target['id']]}
        receipt = intent.claim(receipt, digest(request))
        if not owned(): raise ValueError('cb_color/ownership')
        send(index, request, receipt)
        if not owned(): raise ValueError('cb_color/ownership')
        state, claimed = intent.read()
        if claimed != receipt or state['step'] != index or state['phase'] != 'claimed': raise ValueError('cb_color/intent')
        current = read()
        if operation == 'color': target, row = observe_color(baseline, current, body, target, row, color)
        else:
            target = observe(baseline, current, dict(body, colorStyle=color if operation == 'create' else row['colorStyle']),
                             target=target, deleted=operation == 'delete')
            row = current['marks']['updated'][target['id']] if target else None
        receipt = intent.advance(receipt, target)
    intent.finish(receipt)
    if intent.read() != (None, None): raise ValueError('cb_color/intent')
    return dict(result='PASS', writes=len(STEPS), original_records_restored=True)
