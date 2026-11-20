"""Read-only guard for a prior sealed, potentially delayed empty group."""
from cloud_group_contract import digest, inspect_closed, project


class Guard:
    def __init__(self, journal, binding, grant, current, read_pair):
        self.journal, self.binding, self.grant, self.current, self.read_pair = journal, binding, grant, current, read_pair

    def check(self, require_baseline):
        if type(require_baseline) is not bool or self.current() is not True: raise ValueError('old_group/stale')
        state, token = self.journal.read()
        if (not state or state['phase'] != 'closed_unverified' or state['owner'] != self.grant['vid']
                or state['grant_hash'] != digest(self.grant) and not self.binding.matches(state, token, self.grant)):
            raise ValueError('old_group/binding')
        observations=[]
        for _ in range(2):
            raw=self.read_pair()
            if not isinstance(raw,dict) or set(raw)!={'native','web'}: raise ValueError('old_group/read')
            observations.append(tuple(project(raw[k]) for k in ('native','web')))
        if observations[0] != observations[1] or self.current() is not True: raise ValueError('old_group/changed')
        latest,current_token=self.journal.read()
        if latest!=state or current_token!=token: raise ValueError('old_group/stale')
        for i,key in enumerate(('native_before','web_before')):
            observed=inspect_closed(observations[1][i],state['name'],state[key])
            if observed['present'] or require_baseline and not observed['other_state_unchanged']:
                raise ValueError('old_group/changed')
        return observations[1]
