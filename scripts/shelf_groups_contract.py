"""Independent bounded group membership reference; private values stay in memory."""
from web_shelf_contract import normalize


def project(shelf, unnamed='Unnamed group', ungrouped='Uncategorized'):
    shelf = normalize(shelf)
    regular = [row['bookId'] for row in shelf['books'] if not row['bookId'].startswith('MP_WXS_')]
    known, assigned, keys, groups = set(regular), set(), set(), []
    for archive in shelf['archive']:
        label = archive['name'].strip(' ') or unnamed
        key = 'archive:' + archive['archiveId'] if archive.get('archiveId') else 'name:' + label
        members = list(dict.fromkeys(identity for identity in archive['bookIds'] if identity in known))
        # Only explicitly public-account-only archives are omitted. An empty
        # user group stays selectable even if its old references are unavailable.
        if not members and archive['bookIds'] and all(identity.startswith('MP_WXS_') for identity in archive['bookIds']):
            continue
        if key in keys:
            raise ValueError('ambiguous_group_identity')
        keys.add(key)
        groups.append(dict(key=key,label=label,members=members))
        assigned.update(members)
    remaining = [identity for identity in regular if identity not in assigned]
    if groups and remaining:
        groups.append(dict(key='__ungrouped__',label=ungrouped,members=remaining))
    return groups


def summary(shelf, groups):
    normalized = normalize(shelf)
    known = {row['bookId'] for row in normalized['books']}
    return dict(shelf_books=len(normalized['books']),archives=len(normalized['archive']),
                displayed_groups=len(groups),visible_memberships=sum(len(group['members']) for group in groups),
                empty_groups=sum(not group['members'] for group in groups),
                unavailable_references=sum(identity not in known for group in normalized['archive'] for identity in group['bookIds']))
