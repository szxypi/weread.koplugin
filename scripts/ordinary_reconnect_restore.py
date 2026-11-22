"""One guarded zero-time restoration transport; no automatic retry or resume.

The caller must supply a fresh scoped probe and a coordinator whose two native
reader writes completed. Its before/after callbacks independently check both
services and the relevant account state. This module never creates authority.
"""
from ordinary_reconnect_coordinator import Coordinator
from ordinary_reconnect_body_guard import validate_body
from txt_full_summary import digest
from verify_position_roundtrip import WRITE_URL, canonical, payload
from verify_web_source_progress import WebSourceProbe


class RestoreProbe(WebSourceProbe):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._pending_body = None
        self._used = False

    def guard(self, stage, url, body):
        if stage != 'write_restore':
            return super().guard(stage, url, body)
        if (not self.authenticated or not self.vid or not self.book_id or url != WRITE_URL
                or self._used or self._pending_body is None or not isinstance(body, dict)
                or canonical(body) != self._pending_body
                or next((cookie.value for cookie in self.cookies if cookie.name == 'wr_vid'), None) != self.vid):
            raise ValueError('ordinary_trial/restore_scope')
        # Consume before network dispatch, including exceptions and disconnects.
        self._used = True
        self._pending_body = None

    def _send_once(self, body, coordinator, current):
        if (not isinstance(coordinator, Coordinator) or coordinator.armed is not True
                or coordinator.phase != 'pending' or coordinator.index != 2 or not callable(current)
                or self._used or self._pending_body is not None or not self.authenticated
                or digest(self.vid) != coordinator.plan['owner_sha256']
                or self.book_id != coordinator.plan['baseline']['book_id']):
            raise ValueError('ordinary_trial/restore_scope')
        state, receipt = coordinator.store.read()
        if (not state or state['phase'] != 'restore_pending' or state['plan'] != coordinator.plan
                or receipt != coordinator.receipt or current() is not True):
            raise ValueError('ordinary_trial/currentness')
        validate_body(coordinator.plan, coordinator.context, coordinator.pclts, 'restore', body)
        self._pending_body = canonical(body)
        try:
            response = self.request('write_restore', WRITE_URL, body)
            stages = self.report['stages']
            if not self._used or not stages or stages[-1].get('stage') != 'write_restore':
                raise ValueError('ordinary_trial/restore_transport')
            return stages[-1].get('status'), response
        finally:
            self._pending_body = None


def restore(probe, coordinator, current, report):
    if (not isinstance(probe, RestoreProbe) or not isinstance(coordinator, Coordinator)
            or coordinator.armed is not True or coordinator.index != 2 or coordinator.phase != 'ready'
            or not callable(current) or probe._used or not probe.authenticated
            or digest(probe.vid) != coordinator.plan['owner_sha256']
            or probe.book_id != coordinator.plan['baseline']['book_id']):
        raise ValueError('ordinary_trial/restore_scope')
    point = coordinator.plan['baseline']
    wire = dict(book_id=point['book_id'], baseline=point, target=None,
                context=coordinator.context, pclts=coordinator.pclts)
    report.update(result='UNVERIFIED', restore_claimed=False, restore_claim_interrupted=False,
                  restore_acknowledged=False, restoration_verified=False)
    try:
        if current() is not True: raise ValueError('ordinary_trial/currentness')
        body = payload(wire, 'write_restore')
        report['restore_claim_interrupted'] = True
        if coordinator.claim('restore', body) is not True: raise ValueError('ordinary_trial/blocked')
        report['restore_claimed'] = True
        report['restore_claim_interrupted'] = False
        if current() is not True: raise ValueError('ordinary_trial/currentness')
        status, response = probe._send_once(body, coordinator, current)
        coordinator.ack('restore', status, response); report['restore_acknowledged'] = True
        coordinator.verify('restore'); report.update(result='ORDINARY_RESTORATION_VERIFIED', restoration_verified=True)
    except BaseException:
        coordinator.phase = 'stopped'
        raise
