"""Two explicitly claimed Web requests for one freshly owned fixture."""
from cb_fixture_position_transport import Probe


class ScopedProbe(Probe):
    def __init__(self, plan, owner, authority, intent, reservation):
        super().__init__(plan, owner, authority)
        self.intent, self.reservation, self.permit = intent, reservation, None

    def guard(self, stage, url, request):
        if stage in ('enter', 'same'):
            number = 1 if stage == 'enter' else 2
            if (self.reservation.get('claimed') != number
                    or not self.intent.verify(self.reservation, self.permit)):
                raise ValueError('cb_first/claim')
        elif stage in ('probe', 'restore'):
            raise ValueError('cb_first/claim_scope')
        return super().guard(stage, url, request)

    def send_claimed(self, stage, receipt):
        if (stage not in ('enter', 'same') or self.reservation.get('claimed') != (1 if stage == 'enter' else 2)
                or not self.intent.verify(self.reservation, receipt)):
            raise ValueError('cb_first/claim')
        self.permit = receipt
        try:
            return super().send(stage)
        finally:
            self.permit = None
