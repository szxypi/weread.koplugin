"""Pure checks for a group containing one separately proven fixture book.

These functions do not prove that a CB identity is owned by a trial or permit
any network call; callers must bind it to their durable upload receipt first.
Snapshots and their contents must stay private.
"""
from copy import deepcopy

from cloud_group_contract import group_id, temporary_name
from verify_cb_progress import cb_id


def create_request(name, target):
    if not temporary_name(name) or not cb_id(target):
        raise ValueError('cloud_group_nonempty/target')
    return {'bookIds': [target], 'albumIds': [], 'archiveId': 0, 'name': name}


def without_target(value, target):
    if not cb_id(target): raise ValueError('cloud_group_nonempty/target')
    result = deepcopy(value)
    for row in result['groups'].values():
        row['bookIds'] = [item for item in row['bookIds'] if item != target]
    return result


def created(before, after, name, target, *, require_album_ids=False):
    create_request(name, target)
    if target not in before['members'] or any(row['name'] == name for row in before['groups'].values()):
        raise ValueError('cloud_group_nonempty/baseline')
    if any(before[key] != after[key] for key in ('members', 'flags', 'albums')):
        raise ValueError('cloud_group_nonempty/shelf_changed')
    new = set(after['groups']) - set(before['groups'])
    if len(new) != 1: raise ValueError('cloud_group_nonempty/new_group')
    ident = next(iter(new)); row = after['groups'][ident]
    if (not group_id(ident) or ident == '1' or row.get('name') != name or row.get('bookIds') != [target]
            or require_album_ids and 'albumIds' not in row or row.get('albumIds', []) != []):
        raise ValueError('cloud_group_nonempty/new_group')
    remaining = deepcopy(after); del remaining['groups'][ident]
    if without_target(before, target) != without_target(remaining, target):
        raise ValueError('cloud_group_nonempty/existing_changed')
    return ident


def restored(before, after, target):
    """All original state must match, apart from fixture membership in groups."""
    return without_target(before, target) == without_target(after, target)
