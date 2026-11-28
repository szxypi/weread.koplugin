"""Restrict fixture upload and cleanup to the verified group experiment."""
from cloud_group_fixture import binding
from personal_upload_trial import hash_value
from verify_personal_upload_trial import Probe


class GuardedUploadProbe(Probe):
    def __init__(self, journal, grant_check, group, target, old_guard, pending, opener=None, cos_opener=None):
        super().__init__(journal,grant_check,opener,cos_opener)
        self.group,self.target,self.old_guard,self.pending=group,target,old_guard,pending

    def owns(self, phase, credentials, receipt):
        state=super().owns(phase,credentials,receipt)
        if self.pending() is not True: raise ValueError('group_upload/pending')
        self.old_guard(phase!='cleanup_pending')
        if phase=='cleanup_pending':
            uploaded,_=binding(self.journal,self.target.backend,phase='cleanup_pending')
            group,_=self.group.read()
            if (not group or group['phase']!='restored' or group['target']!=uploaded['target']
                    or group['upload_attempt']!=uploaded['attempt'] or group['upload_plan_hash']!=hash_value(uploaded['plan'])
                    or group['owner']!=uploaded['plan']['owner'] or group['grant_hash']!=uploaded['plan']['grant_sha256']):
                raise ValueError('group_upload/not_restored')
        return state
