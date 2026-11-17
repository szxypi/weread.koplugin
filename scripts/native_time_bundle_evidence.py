"""Private in-memory preflight evidence; no transport or dispatch capability."""
from copy import deepcopy

from annotation_experiment_model import digest
from native_time_bundle_accounting import baseline
from readtime_upload_model import integer


class PreflightEvidence:
    """Bind a sanitized report to the exact private preflight observations.

    This protects against accidental mutation and disclosure, not hostile code
    running in the same process. Authenticity comes from the scoped reader.
    """
    def __init__(self,bundle,grant,report,snapshot,months):
        flags=('exact_capture_and_fixture_bound','fixture_in_captured_baseline',
               'both_positions_source_counts_and_original_shelf_exact','two_statistics_reads_stable','server_clock_after_boundary')
        fields=set(flags)|{'result','seconds','observed_months','completed_at','account_data_posts',
                           'authentication_posts','historical_accounting_verified','dispatch_capability'}
        if (not isinstance(report,dict) or set(report)!=fields or report['result']!='CROSS_DAY_READONLY_VERIFIED'
                or any(report[key] is not True for key in flags)
                or type(report['seconds']) is not int or report['seconds']!=bundle['plan']['seconds']
                or not integer(report['completed_at'],bundle['plan']['not_before'],4102444800)
                or type(report['observed_months']) is not int or report['observed_months']!=len(months)
                or any(type(report[key]) is not int or report[key]!=0 for key in ('account_data_posts','authentication_posts'))
                or report['historical_accounting_verified'] is not False or report['dispatch_capability'] is not False):
            raise ValueError('bundle_evidence/report')
        original=baseline(bundle,grant,snapshot,months,report['completed_at'])
        self._value=deepcopy((report,original))
        self._bundle_hash=digest(bundle);self._grant_hash=digest(grant)
        self._value_hash=digest(self._value)

    def __repr__(self):
        return '<PreflightEvidence private>'

    def for_bundle(self,bundle,grant):
        if (digest(bundle)!=self._bundle_hash or digest(grant)!=self._grant_hash
                or digest(self._value)!=self._value_hash):raise ValueError('bundle_evidence/changed')
        report,original=deepcopy(self._value)
        if baseline(bundle,grant,original['snapshot'],original['months'],report['completed_at'])!=original:
            raise ValueError('bundle_evidence/changed')
        return report,original['snapshot'],original['months']
