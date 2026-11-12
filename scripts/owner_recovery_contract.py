"""Strict private envelopes for the explicitly opted-in parent renewal probe."""
from datetime import datetime, timezone
import json
import re

from secure_native_session import validate as validate_native
from secure_weread_session import ACCOUNT
from verify_owner_reading import FRAME, decode_envelope
import owner_annotation_contract as annotations
from verify_native_annotations import range_value


RECOVERY_LIMITS = dict(first_native_status=599, authentication_posts=1, renewal_shelf_reads=1,
                       renewal_shelf_status=599, saved_revision=3, guard_denied=1024, failed_line=10000, store_write_attempts=2)
RECOVERY_FLAGS = {'saved_new_grant', 'renewal_pending'}
MODEL_FIELDS = {'ranges', 'digest', 'source_quotes_digest', 'underlines', 'thought_items'}


def credentials(value, owner):
    return validate_native(dict(schema=1, scope=ACCOUNT, kind='eink',
                                created_at=datetime.now(timezone.utc).isoformat(), credentials=value), owner)['credentials']


def private(value, owner, mode, complete):
    if not isinstance(value, dict) or set(value) != {'guard_installed', 'recovery', 'credentials', 'model'} or value['guard_installed'] is not True:
        raise ValueError('recovery_private_schema')
    stats = value['recovery']
    if (not isinstance(stats, dict) or set(stats) != set(RECOVERY_LIMITS) | RECOVERY_FLAGS
            or any(type(stats[k]) is not int or not 0 <= stats[k] <= n for k, n in RECOVERY_LIMITS.items())
            or any(type(stats[k]) is not bool for k in RECOVERY_FLAGS) or stats['saved_revision'] < 1):
        raise ValueError('recovery_stats')
    if stats['saved_new_grant']:
        if (mode != 'live' or stats['first_native_status'] != 401 or stats['authentication_posts'] != 1
                or stats['renewal_shelf_reads'] != 1 or stats['renewal_shelf_status'] != 200
                or stats['saved_revision'] != 3 or stats['renewal_pending'] or stats['store_write_attempts'] != 2):
            raise ValueError('recovery_save_unverified')
        credentials(value['credentials'], owner)
    elif value['credentials'] is not None:
        raise ValueError('recovery_unconfirmed_credentials')
    if mode == 'reopen' and (stats['authentication_posts'] or stats['renewal_shelf_reads'] or stats['first_native_status'] or stats['store_write_attempts']):
        raise ValueError('recovery_offline_network')
    model = value['model']
    if model is not None:
        if (mode != 'live' or not isinstance(model, dict) or set(model) != MODEL_FIELDS
                or type(model['underlines']) is not int or not 1 <= model['underlines'] <= 4096
                or type(model['thought_items']) is not int or not 1 <= model['thought_items'] <= 122880
                or not isinstance(model['ranges'], list) or len(model['ranges']) != model['underlines']
                or len(set(model['ranges'])) != len(model['ranges'])
                or any(not isinstance(model[k], str) or not re.fullmatch('[0-9a-f]{64}', model[k]) for k in ('digest','source_quotes_digest'))):
            raise ValueError('recovery_model_schema')
        for marker in model['ranges']: range_value(marker)
    if complete and (stats['guard_denied'] or stats['failed_line']
            or mode == 'live' and (not stats['saved_new_grant'] or model is None)):
        raise ValueError('recovery_incomplete')


def annotation_stage(value, mode, complete):
    if not isinstance(value, dict) or set(value) != annotations.FLAGS | set(annotations.COUNTS):
        raise ValueError('recovery_annotation_schema')
    limits = dict(annotations.COUNTS, native_underlines_requests=2 if mode == 'live' else 0)
    if (any(type(value[k]) is not bool for k in annotations.FLAGS)
            or any(type(value[k]) is not int or not 0 <= value[k] <= n for k,n in limits.items())):
        raise ValueError('recovery_annotation_types')
    pending = {'source_data_matches', 'source_quote_recheck_verified'} if mode == 'live' else set()
    if complete and (not all(value[k] for k in annotations.FLAGS-pending)
            or any(value[k] for k in pending) or value['native_denied_requests'] or value['failed_line']
            or not value['underlines'] or not value['thought_items'] or not value['located']
            or value['partial'] > value['located']
            or value['located']+value['unmatched'] != value['underlines']
            or mode == 'live' and (value['native_underlines_requests'] != 2
                or value['native_thought_requests'] != (value['underlines']+29)//30)):
        raise ValueError('recovery_annotation_incomplete')
    if mode == 'reopen' and value['native_thought_requests']:
        raise ValueError('recovery_annotation_offline')


def decode(raw, owner, *, mode=None, full_chapters=1):
    if full_chapters != 1 or not isinstance(raw, bytes) or len(raw) > 2*1024*1024 or raw.count(FRAME) != 1:
        raise ValueError('recovery_frame')
    envelope = json.loads(raw.split(FRAME)[1])
    if not isinstance(envelope, dict) or set(envelope) != {'report','cookies','recovery_private'}:
        raise ValueError('recovery_envelope')
    secret = envelope.pop('recovery_private')
    report = envelope['report']
    stages = [report] if mode else report['stages']
    secrets = [secret] if mode else secret
    if not isinstance(secrets, list) or len(secrets) != len(stages) or len(stages) > 2:
        raise ValueError('recovery_stages')
    addons = []
    for index, stage in enumerate(stages):
        phase = mode or ('live','reopen')[index]
        addon = stage.pop('annotations')
        complete = stage.get('result') == 'PASS'
        annotation_stage(addon, phase, complete)
        private(secrets[index], owner, phase, complete)
        addons.append(addon)
    checked = decode_envelope(FRAME+json.dumps(envelope).encode(), owner, mode=mode)
    target = [checked['report']] if mode else checked['report']['stages']
    for stage, addon in zip(target,addons): stage['annotations'] = addon
    if mode is None and report.get('result') == 'PASS':
        for key in ('underlines','thought_items','located','unmatched','partial'):
            if addons[0][key] != addons[1][key]: raise ValueError('recovery_offline_model_changed')
    checked['recovery_private'] = secret
    return checked


def compare_postflight(model, expected):
    """Expected is independently fetched after renewal, never learned from Lua."""
    for field in MODEL_FIELDS:
        first, second = model[field], expected[field]
        if field == 'ranges': first, second = sorted(first), sorted(second)
        if type(first) is not type(second) or first != second:
            raise ValueError('recovery_independent_model_mismatch')
