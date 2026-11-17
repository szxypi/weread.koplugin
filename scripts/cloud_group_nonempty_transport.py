"""Narrow native transport; this module has no command-line write entry point."""
from cloud_group_contract import delete_request, digest
from cloud_group_nonempty_contract import create_request
from personal_upload_trial import hash_value
from verify_cloud_group_trial import FULL_SHELF
from verify_eink_login import BASE, NativeProbe, ProbeError


class ScopedNative(NativeProbe):
    def __init__(self, journal, fixture, grant, current, pending_check, old_group_absent, opener=None):
        super().__init__(opener)
        self.journal, self.fixture, self.grant, self.current = journal, fixture, grant, current
        self.pending_check, self.old_group_absent = pending_check, old_group_absent
        self.dispatched=set(); self.write_attempts=0

    def shelf(self):
        if self.current() is not True: raise ProbeError('group_nonempty_scope')
        return super().request('group_shelf', FULL_SHELF, credentials=self.grant)

    def post(self, path, body):
        if self.current() is not True or self.pending_check() is not True or self.old_group_absent() is not True:
            raise ProbeError('group_nonempty_scope')
        state, token = self.journal.read(); upload, _ = self.fixture()
        if (not state or upload['phase'] != 'imported' or state['owner'] != self.grant['vid']
                or state['grant_hash'] != digest(self.grant) or state['target'] != upload['target']
                or state['upload_attempt'] != upload['attempt'] or state['upload_plan_hash'] != hash_value(upload['plan'])
                or upload['plan']['owner'] != state['owner'] or upload['plan']['grant_sha256'] != state['grant_hash']):
            raise ProbeError('group_nonempty_scope')
        if path == '/shelf/archive' and state['phase'] == 'create_claimed':
            expected = create_request(state['name'], state['target'])
        elif path == '/shelf/deleteArchive' and state['phase'] == 'delete_claimed':
            expected = delete_request(state['group_id'])
        else: raise ProbeError('group_nonempty_scope')
        if body != expected or state['phase'] in self.dispatched or state['dispatched'] or self.current() is not True:
            raise ProbeError('group_nonempty_scope')
        self.journal.claim_dispatch(token, state['phase'])
        self.dispatched.add(state['phase']); self.write_attempts += 1
        return super().request('group_write', BASE + path, body=body, credentials=self.grant)
