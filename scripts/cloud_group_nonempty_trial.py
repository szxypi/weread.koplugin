"""Transport-independent, fail-closed nonempty-group experiment.

The caller must supply a separately scoped transport that enforces each
claimed journal phase and exact request; this module does not provide one.
"""
import secrets
import time

from cloud_group_contract import acknowledged, delete_request, digest, project
from cloud_group_nonempty_contract import create_request, created, restored
from cloud_group_trial import _cross_channel
from personal_upload_trial import hash_value


class Trial:
    def __init__(self, journal, fixture, read_pair, post, current, sleep=time.sleep):
        self.journal, self.fixture, self.read_pair, self.post, self.current, self.sleep = journal, fixture, read_pair, post, current, sleep

    def _bound(self, expected):
        state, token = self.fixture()
        if (self.current() is not True or state['phase'] != 'imported' or state['target'] != expected['target']
                or state['attempt'] != expected['upload_attempt'] or hash_value(state['plan']) != expected['upload_plan_hash']
                or state['plan']['owner'] != expected['owner'] or state['plan']['grant_sha256'] != expected['grant_hash']):
            raise ValueError('cloud_group_nonempty/binding')
        return token

    def _read(self, expected, *, match=True):
        self._bound(expected); raw = self.read_pair()
        if not isinstance(raw, dict) or set(raw) != {'native', 'web'}: raise ValueError('cloud_group_nonempty/read')
        values = project(raw['native']), project(raw['web'])
        if match and not _cross_channel(*values): raise ValueError('cloud_group_nonempty/channels')
        self._bound(expected)
        return values

    def _dispatch_token(self, expected, name, before, phase, ident):
        state, token = self.journal.read()
        if (not state or state['phase'] != phase or state['dispatched'] is not True or state['name'] != name
                or state['group_id'] != ident or state['native_before'] != digest(before[0])
                or state['web_before'] != digest(before[1]) or any(state[k] != v for k, v in expected.items())):
            raise ValueError('cloud_group_nonempty/journal_changed')
        self._bound(expected)
        return token

    def run(self):
        report = dict(result='UNVERIFIED', phase='preflight', data_posts=0, create_ack=False, delete_ack=False, restored=False)
        try:
            if self.journal.read()[0] is not None:
                report['phase'] = 'scope_consumed'; return report
            state, _ = self.fixture()
            expected = dict(owner=state['plan']['owner'], grant_hash=state['plan']['grant_sha256'], target=state['target'],
                            upload_attempt=state['attempt'], upload_plan_hash=hash_value(state['plan']))
            before = self._read(expected)
            if self._read(expected) != before: raise ValueError('cloud_group_nonempty/changed')
            if not before[0]['albums']['present'] or any('albumIds' not in row for row in before[0]['groups'].values()):
                raise ValueError('cloud_group_nonempty/album_visibility')
            name = 'KOReader-Test-' + secrets.token_hex(12)
            if any(row['name'] == name for channel in before for row in channel['groups'].values()):
                raise ValueError('cloud_group_nonempty/collision')
            token = self.journal.begin(**expected, name=name, native_before=digest(before[0]), web_before=digest(before[1]))
            report['phase'] = 'prepared'
            if self._read(expected) != before: raise ValueError('cloud_group_nonempty/changed')
            token = self.journal.advance(token, 'create_claimed'); report['phase'] = 'create_claimed'
            self._bound(expected); report['data_posts'] += 1
            try: response = self.post('/shelf/archive', create_request(name, expected['target']))
            except Exception: response = None
            report['create_ack'] = acknowledged(response)
            after = None; ident = None
            for attempt in range(3):
                if attempt: self.sleep(.5 * attempt)
                pair = self._read(expected, match=False); ids = []
                for i, value in enumerate(pair):
                    ids.append(None if value == before[i] else created(before[i], value, name, expected['target'], require_album_ids=i == 0))
                if ids[0] is not None and ids[0] == ids[1]: ident, after = ids[0], pair; break
                if ids[0] is not None and ids[1] is not None: raise ValueError('cloud_group_nonempty/identity')
            if not report['create_ack'] or ident is None:
                report['phase'] = 'create_unverified'; return report
            token = self._dispatch_token(expected, name, before, 'create_claimed', None)
            token = self.journal.advance(token, 'created', group_id_value=ident); report['phase'] = 'created'
            if self._read(expected) != after: raise ValueError('cloud_group_nonempty/changed')
            token = self.journal.advance(token, 'delete_claimed'); report['phase'] = 'delete_claimed'
            self._bound(expected); report['data_posts'] += 1
            try: response = self.post('/shelf/deleteArchive', delete_request(ident))
            except Exception: response = None
            report['delete_ack'] = acknowledged(response)
            for attempt in range(3):
                if attempt: self.sleep(.5 * attempt)
                pair = self._read(expected, match=False)
                if any(not restored(before[i], pair[i], expected['target']) and pair[i] != after[i] for i in range(2)):
                    raise ValueError('cloud_group_nonempty/unrelated_change')
                if all(restored(before[i], pair[i], expected['target']) for i in range(2)):
                    report['restored'] = True; break
            if report['delete_ack'] and report['restored'] and self._read(expected) == pair:
                token = self._dispatch_token(expected, name, before, 'delete_claimed', ident)
                self.journal.advance(token, 'restored'); report.update(result='PASS', phase='restored')
            else: report['phase'] = 'delete_unverified'
        except Exception:
            pass
        return report
