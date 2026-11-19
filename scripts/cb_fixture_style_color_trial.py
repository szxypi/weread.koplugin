"""Source-bound imported highlights covering all styles and colors."""
from pathlib import Path
import tempfile

from annotation_experiment_model import digest
from cb_fixture_highlight_trial import prepare as prepare_highlight, validate_plan as validate_highlight
from highlight_trial_model import observe
from mark_style_trial_model import target_valid
from secure_mark_color import MarkColorStore
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain

PROTOCOL = 'cb-synthetic-highlight-style-color-matrix-v1'
SERVICE = 'org.codex.weread.cb-fixture-style-color-intent-v1'


def make_steps():
    steps = []
    for initial in (0, 2):
        for color in range(6):
            steps.append(('create', (initial, color)))
            if color == 0:
                steps.extend(('color', (initial, c)) for c in (1, 2, 3, 4, 5, 0))
            other = 2 if initial == 0 else 0
            steps.extend((('style', (other, color)), ('style', (1, color)), ('style', (initial, color)), ('delete', None)))
    return tuple(steps)


STEPS = make_steps()


def validate_plan(value):
    if (not isinstance(value, dict) or set(value) != {'protocol', 'highlight', 'creation_hashes'}
            or value['protocol'] != PROTOCOL or not isinstance(value['creation_hashes'], list)
            or len(value['creation_hashes']) != 18
            or any(not isinstance(v, str) or len(v) != 64 or any(c not in '0123456789abcdef' for c in v)
                   for v in value['creation_hashes']) or len(set(value['creation_hashes'])) != 18):
        raise ValueError('cb_matrix/plan')
    validate_highlight(value['highlight'])
    if value['highlight']['request_sha256'] != value['creation_hashes'][6]: raise ValueError('cb_matrix/plan')
    return value


def dispatch_hash(plan, step, target):
    validate_plan(plan)
    if type(step) is not int or not 0 <= step < len(STEPS): raise ValueError('cb_matrix/step')
    operation, choice = STEPS[step]
    if operation == 'create':
        if target is not None: raise ValueError('cb_matrix/target')
        style, color = choice
        return plan['creation_hashes'][style * 6 + color]
    if not target_valid(target): raise ValueError('cb_matrix/target')
    if operation == 'delete': body = {'bookmarkIds': [target['id']]}
    else:
        style, color = choice
        body = dict(bookmarkId=target['id'], style=style, colorStyle=color)
    return digest(body)


class Intent(MarkColorStore):
    steps = STEPS
    validate_plan = staticmethod(validate_plan)
    dispatch_hash = staticmethod(dispatch_hash)
    def __init__(self, backend=None, lock=None):
        if backend is None:
            backend = MacKeychain(service=SERVICE, account=ACCOUNT)
            path = Path(tempfile.gettempdir()) / ('codex-cb-fixture-matrix-' + ACCOUNT + '.lock')
            lock = lock or (lambda: project_lock(path))
        super().__init__(backend, lock)


def prepare(owner, book, attempt, sample, version, baseline):
    highlight, body = prepare_highlight(owner, book, attempt, sample, version, baseline)
    plan = dict(protocol=PROTOCOL, highlight=highlight,
                creation_hashes=[digest(dict(body, style=s, colorStyle=c)) for s in range(3) for c in range(6)])
    return validate_plan(plan), body


def execute(plan, body, baseline, intent, owned, read, send):
    validate_plan(plan)
    if (digest(body) != plan['highlight']['request_sha256'] or digest(baseline) != plan['highlight']['baseline_sha256']
            or not owned() or intent.read()[0] is not None or read() != baseline or read() != baseline or not owned()):
        raise ValueError('cb_matrix/preflight')
    receipt = intent.reserve(plan); target = row = None
    for index, (operation, choice) in enumerate(STEPS):
        if not owned(): raise ValueError('cb_matrix/ownership')
        current = read()
        old_body = dict(body, style=row['style'], colorStyle=row['colorStyle']) if row else body
        observe(baseline, current, old_body, target=target, deleted=target is None)
        if operation == 'create':
            style, color = choice; request = dict(body, style=style, colorStyle=color)
        elif operation == 'delete': request = {'bookmarkIds': [target['id']]}
        else:
            style, color = choice
            if (operation == 'style' and (style == row['style'] or color != row['colorStyle'])
                    or operation == 'color' and (style != row['style'] or color == row['colorStyle'])):
                raise ValueError('cb_matrix/change')
            request = dict(bookmarkId=target['id'], style=style, colorStyle=color)
        receipt = intent.claim(receipt, digest(request))
        if not owned(): raise ValueError('cb_matrix/ownership')
        send(index, request, receipt)
        if not owned(): raise ValueError('cb_matrix/ownership')
        state, claimed = intent.read()
        if claimed != receipt or state['step'] != index or state['phase'] != 'claimed': raise ValueError('cb_matrix/intent')
        current = read()
        if operation == 'delete':
            observe(baseline, current, old_body, target=target, deleted=True); target = row = None
        else:
            expected = dict(body, style=style, colorStyle=color)
            found = observe(baseline, current, expected)
            next_row = current['marks']['updated'][found['id']]
            if target is not None and (found['id'] != target['id'] or next_row != dict(row, style=style, colorStyle=color)):
                raise ValueError('cb_matrix/changed')
            target, row = found, next_row
        receipt = intent.advance(receipt, target)
    intent.finish(receipt)
    if intent.read() != (None, None): raise ValueError('cb_matrix/intent')
    return dict(result='PASS', writes=len(STEPS), original_records_restored=True)
