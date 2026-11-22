"""In-memory host gate for the one-shot ordinary XHTML trial.

No HTTP, UI, Keychain creation, replay, or recovery operation is performed here.
The caller provides independent before/after checks and the actual response.
"""
from copy import deepcopy
from ordinary_reconnect_body_guard import validate_body
from secure_ordinary_reconnect_trial import validate_plan
from verify_position_roundtrip import acknowledged

STAGES = ('enter', 'position', 'restore')


class Coordinator:
    def __init__(self, store, plan, context, pclts, before, after, *, armed=False):
        validate_plan(plan)
        state, receipt = store.read()
        if (type(armed) is not bool or not state or state['phase'] != 'prepared' or state['plan'] != plan
                or not callable(before) or not callable(after)):
            raise ValueError('ordinary_trial/coordinator')
        self.store, self.plan, self.context, self.pclts = store, deepcopy(plan), deepcopy(context), pclts
        self.before, self.after, self.armed = before, after, armed
        self.receipt = receipt
        self.index = 0
        self.phase = 'ready'

    def claim(self, stage, body):
        try:
            return self._claim(stage, body)
        except Exception:
            self.phase = 'stopped'
            raise

    def _claim(self, stage, body):
        if self.phase != 'ready' or self.index >= len(STAGES) or stage != STAGES[self.index]:
            raise ValueError('ordinary_trial/sequence')
        validate_body(self.plan, self.context, self.pclts, stage, body)
        if self.before(stage, deepcopy(self.plan)) is not True:
            raise ValueError('ordinary_trial/before')
        if not self.armed:
            self.phase = 'blocked'
            return False
        previous = 'prepared' if self.index == 0 else STAGES[self.index-1] + '_verified'
        self.receipt = self.store.advance(self.receipt, previous, stage + '_pending')
        self.phase = 'pending'
        return True

    def ack(self, stage, status, response):
        try:
            return self._ack(stage, status, response)
        except Exception:
            self.phase = 'stopped'
            raise

    def _ack(self, stage, status, response):
        if self.phase != 'pending' or stage != STAGES[self.index]:
            raise ValueError('ordinary_trial/sequence')
        if type(status) is not int or not 200 <= status < 300 or acknowledged(response) is not True:
            raise ValueError('ordinary_trial/ack')
        self.receipt = self.store.advance(self.receipt, stage + '_pending', stage + '_acknowledged')
        self.phase = 'acknowledged'

    def verify(self, stage):
        try:
            return self._verify(stage)
        except Exception:
            self.phase = 'stopped'
            raise

    def _verify(self, stage):
        if self.phase != 'acknowledged' or stage != STAGES[self.index]:
            raise ValueError('ordinary_trial/sequence')
        if self.after(stage, deepcopy(self.plan)) is not True:
            raise ValueError('ordinary_trial/after')
        following = 'retired' if stage == 'restore' else stage + '_verified'
        self.receipt = self.store.advance(self.receipt, stage + '_acknowledged', following)
        self.index += 1
        self.phase = 'done' if self.index == len(STAGES) else 'ready'
