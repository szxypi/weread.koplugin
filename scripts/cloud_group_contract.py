"""Bounded, private snapshot checks for a single temporary empty shelf group.

Wire shapes are informed by the client research at
https://github.com/tanyaqiongcode/weread-shelf-organizer/blob/main/references/api.md;
they are not treated as verified for the E-Ink credential until a real trial.
No function in this module performs I/O or grants permission to send.
"""
from copy import deepcopy
import hashlib
import json
import re

from finish_change_contract import flags, flags_hash
from web_shelf_contract import identity, normalize, text


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode('utf-8')


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def group_id(value):
    value = identity(value)
    return value if value and re.fullmatch(r'[1-9][0-9]{0,15}', value) and int(value) <= 9007199254740991 else None


def temporary_name(value):
    return isinstance(value, str) and re.fullmatch(r'KOReader-Test-[a-f0-9]{24}', value) is not None


def _ids(values):
    if not isinstance(values, list) or len(values) > 5000:
        raise ValueError('cloud_group/members')
    ids = [identity(item) for item in values]
    if any(item is None for item in ids) or len(set(ids)) != len(ids):
        raise ValueError('cloud_group/members')
    return sorted(ids)


def project(source):
    """Keep observed group details, shelf membership/flags and album fields.

    Results may contain private IDs and names and must stay in memory.
    Missing album information stays missing rather than being treated as empty.
    """
    shelf = normalize(source)
    state = flags(source)
    if any(flag.get('reason') == 'invalid' for row in state.values() for flag in row.values()):
        raise ValueError('cloud_group/flags')
    groups = {}
    for raw in source.get('archive', []):
        if not isinstance(raw, dict):
            raise ValueError('cloud_group/archive')
        ident = group_id(raw.get('archiveId'))
        if not ident or ident in groups or not text(raw.get('name'), 4096):
            raise ValueError('cloud_group/archive')
        row = deepcopy(raw)
        row['archiveId'] = ident
        row['bookIds'] = _ids(raw.get('bookIds'))
        if 'albumIds' in raw:
            row['albumIds'] = _ids(raw['albumIds'])
        canonical(row)  # reject non-JSON and non-finite values
        groups[ident] = row
    albums = dict(present='albums' in source)
    if albums['present']:
        if not isinstance(source['albums'], list) or len(source['albums']) > 5000:
            raise ValueError('cloud_group/albums')
        albums['value'] = deepcopy(source['albums'])
        canonical(albums['value'])
    return dict(members=sorted(row['bookId'] for row in shelf['books']), flags=flags_hash(state),
                groups=groups, albums=albums)


def create_request(name):
    if not temporary_name(name):
        raise ValueError('cloud_group/name')
    return {'bookIds': [], 'albumIds': [], 'archiveId': 0, 'name': name}


def delete_request(ident):
    if not isinstance(ident, str) or not group_id(ident) or ident == '1':
        raise ValueError('cloud_group/id')
    return {'archiveId': int(ident), 'removeBooks': 0}


def created(before, after, name, *, require_album_ids=False):
    if not temporary_name(name) or any(row['name'] == name for row in before['groups'].values()):
        raise ValueError('cloud_group/name')
    if any(before[key] != after[key] for key in ('members', 'flags', 'albums')):
        raise ValueError('cloud_group/shelf_changed')
    if any(after['groups'].get(key) != row for key, row in before['groups'].items()):
        raise ValueError('cloud_group/existing_changed')
    new = set(after['groups']) - set(before['groups'])
    if len(new) != 1:
        raise ValueError('cloud_group/new_group')
    ident = next(iter(new)); row = after['groups'][ident]
    if (ident == '1' or row.get('name') != name or row.get('bookIds') != []
            or require_album_ids and 'albumIds' not in row or row.get('albumIds', []) != []):
        raise ValueError('cloud_group/new_group')
    return ident


def restored(before, after):
    return before == after


def inspect_closed(value, name, before_hash):
    """Inspect a possibly delayed group; the returned ID is private to callers."""
    if not temporary_name(name) or not isinstance(before_hash,str) or not re.fullmatch('[a-f0-9]{64}',before_hash):
        raise ValueError('cloud_group/inspect')
    matches=[(key,row) for key,row in value['groups'].items() if row['name']==name]
    if len(matches)>1:raise ValueError('cloud_group/inspect_ambiguous')
    ident,row=matches[0] if matches else (None,None)
    other=dict(value);other['groups']=dict(value['groups'])
    if ident:other['groups'].pop(ident)
    return dict(ident=ident,present=ident is not None,other_state_unchanged=digest(other)==before_hash,
                empty_books=row is not None and row.get('bookIds')==[],
                albums_visible=row is not None and 'albumIds' in row,
                empty_albums=row is not None and row.get('albumIds')==[])


def acknowledged(response):
    if not isinstance(response, dict) or type(response.get('succ')) is not int or response['succ'] != 1:
        return False
    for key in ('errcode', 'errCode'):
        value=response.get(key)
        if value is not None and (type(value) is not int or value != 0): return False
    return response.get('success', True) is True
