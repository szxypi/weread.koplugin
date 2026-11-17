"""One create/readback/delete/readback trial for a new, empty group.

Transport, credentials and logging are supplied by the caller. The journal
permanently seals each POST before dispatch; an uncertain attempt is not retried.
"""
import secrets
import time

from cloud_group_contract import acknowledged, create_request, created, delete_request, digest, project, restored


def _cross_channel(left, right):
    def groups(value):
        return {key: (row['name'], tuple(row['bookIds'])) for key, row in value['groups'].items()}
    return left['members'] == right['members'] and groups(left) == groups(right)


class Trial:
    def __init__(self, journal, read_pair, post, current, sleep=time.sleep):
        self.journal, self.read_pair, self.post, self.current, self.sleep = journal, read_pair, post, current, sleep

    def _read(self, *, require_match=True):
        if self.current() is not True: raise ValueError('cloud_group/stale')
        raw = self.read_pair()
        if not isinstance(raw, dict) or set(raw) != {'native', 'web'}: raise ValueError('cloud_group/read')
        native, web = project(raw['native']), project(raw['web'])
        if require_match and not _cross_channel(native, web): raise ValueError('cloud_group/channels')
        if self.current() is not True: raise ValueError('cloud_group/stale')
        return native, web

    def observe_stable(self):
        first = self._read(); second = self._read()
        if first != second: raise ValueError('cloud_group/changed')
        return first, second

    def preview(self):
        return self.observe_stable()[0]

    def _observe_created(self, before, name):
        for attempt in range(3):
            if attempt: self.sleep(.5 * attempt)
            pair = self._read(require_match=False); ids = []
            for index, value in enumerate(pair):
                if value == before[index]: ids.append(None)
                else: ids.append(created(before[index], value, name, require_album_ids=index == 0))
            if ids[0] is not None and ids[0] == ids[1]: return ids[0], pair
            if ids[0] is not None and ids[1] is not None: raise ValueError('cloud_group/identity')
        return None, None

    def _observe_restored(self, before, after):
        for attempt in range(3):
            if attempt: self.sleep(.5 * attempt)
            pair = self._read(require_match=False)
            if any(pair[i] != before[i] and pair[i] != after[i] for i in range(2)):
                raise ValueError('cloud_group/unrelated_change')
            if all(restored(before[i], pair[i]) for i in range(2)): return True
        return False

    def run(self, owner, grant_hash):
        report = dict(result='UNVERIFIED', phase='preflight', data_posts=0,
                      create_ack=False, delete_ack=False, restored=False)
        try:
            if self.journal.read()[0] is not None:
                report['phase'] = 'scope_consumed';return report
            before = self.preview()
            # The native full-shelf query must actually expose album state.
            if not before[0]['albums']['present'] or any('albumIds' not in g for g in before[0]['groups'].values()):
                raise ValueError('cloud_group/album_visibility')
            name = 'KOReader-Test-' + secrets.token_hex(12)
            if any(row['name'] == name for channel in before for row in channel['groups'].values()):
                raise ValueError('cloud_group/name_collision')
            token = self.journal.begin(owner, grant_hash, name, digest(before[0]), digest(before[1]))
            report['phase'] = 'prepared'
            if self._read() != before: raise ValueError('cloud_group/changed')
            token = self.journal.advance(token, 'create_claimed'); report['phase'] = 'create_claimed'
            if self.current() is not True: raise ValueError('cloud_group/stale')
            report['data_posts'] += 1
            try: response = self.post('/shelf/archive', create_request(name))
            except Exception: response = None
            report['create_ack'] = acknowledged(response)
            ident, after = self._observe_created(before, name)
            if not report['create_ack'] or ident is None:
                report['phase'] = 'create_unverified';return report
            token = self.journal.advance(token, 'created', group_id_value=ident);report['phase'] = 'created'
            if self._read() != after: raise ValueError('cloud_group/changed')
            token = self.journal.advance(token, 'delete_claimed');report['phase'] = 'delete_claimed'
            if self.current() is not True: raise ValueError('cloud_group/stale')
            report['data_posts'] += 1
            try: response = self.post('/shelf/deleteArchive', delete_request(ident))
            except Exception: response = None
            report['delete_ack'] = acknowledged(response)
            report['restored'] = self._observe_restored(before, after)
            if report['delete_ack'] and report['restored']:
                self.journal.advance(token, 'restored');report.update(result='PASS', phase='restored')
            else: report['phase'] = 'delete_unverified'
        except Exception:
            # The durable journal is authoritative about whether a POST was
            # already claimed. No exception triggers a new dispatch.
            pass
        return report
