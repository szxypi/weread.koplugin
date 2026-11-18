"""Private in-memory preflight evidence; no transport or dispatch capability."""
from copy import deepcopy

from annotation_experiment_model import digest
from native_time_bundle_accounting import baseline
from readtime_upload_model import integer
from source_currentness import catalog


def catalog_stamp(bundle,catalog_pairs):
    p=bundle['plan']
    if (not isinstance(catalog_pairs,list) or len(catalog_pairs)!=2
            or any(not isinstance(pair,list) or len(pair)!=2 for pair in catalog_pairs)):
        raise ValueError('bundle_evidence/catalog')
    try:
        results=[catalog(payload,p['book_id'],p['chapter_uid']) for pair in catalog_pairs for payload in pair]
    except (ValueError,TypeError,KeyError,StopIteration):raise ValueError('bundle_evidence/catalog') from None
    if any(value!=results[0] for value in results[1:]) or results[0][0]!=p['chapter_idx']:
        raise ValueError('bundle_evidence/catalog')
    return results[0][1]


def validate_fresh_report(bundle,report,months,shelf_digests,trial_scope):
    import re
    from native_time_bundle_trial_scope import validate
    flags=('exact_capture_and_fixture_bound','fixture_in_captured_baseline',
           'captured_native_shelf_positions_source_counts_exact','fresh_native_and_web_shelf_stable',
           'two_statistics_reads_stable','server_clock_after_boundary')
    previous=('previous_native_group_baseline_matches','previous_web_group_baseline_matches')
    fields=set(flags)|set(previous)|{'result','seconds','observed_months','completed_at','account_data_posts',
                                     'authentication_posts','historical_accounting_verified','dispatch_capability'}
    if (not isinstance(report,dict) or set(report)!=fields or report['result']!='CAPTURE_FRESH_SHELF_READONLY_VERIFIED'
            or any(report[key] is not True for key in flags) or any(type(report[key]) is not bool for key in previous)
            or type(report['seconds']) is not int or report['seconds']!=bundle['plan']['seconds']
            or not integer(report['completed_at'],bundle['plan']['not_before'],4102444800)
            or not isinstance(months,dict) or type(report['observed_months']) is not int or report['observed_months']!=len(months)
            or any(type(report[key]) is not int or report[key]!=0 for key in ('account_data_posts','authentication_posts'))
            or report['historical_accounting_verified'] is not False or report['dispatch_capability'] is not False
            or not isinstance(shelf_digests,(tuple,list)) or len(shelf_digests)!=2
            or any(not isinstance(value,str) or not re.fullmatch('[a-f0-9]{64}',value) for value in shelf_digests)):
        raise ValueError('bundle_evidence/fresh_report')
    validate(bundle,trial_scope)


class PreflightEvidence:
    """Bind a sanitized report to the exact private preflight observations.

    This protects against accidental mutation and disclosure, not hostile code
    running in the same process. Authenticity comes from the scoped reader.
    """
    def __init__(self,bundle,grant,report,snapshot,months,catalog_pairs):
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
        self._value=deepcopy((report,original,catalog_stamp(bundle,catalog_pairs)))
        self._bundle_hash=digest(bundle);self._grant_hash=digest(grant)
        self._value_hash=digest(self._value)

    def __repr__(self):
        return '<PreflightEvidence private>'

    def for_bundle(self,bundle,grant):
        if (digest(bundle)!=self._bundle_hash or digest(grant)!=self._grant_hash
                or digest(self._value)!=self._value_hash):raise ValueError('bundle_evidence/changed')
        report,original,_catalog_stamp=deepcopy(self._value)
        if baseline(bundle,grant,original['snapshot'],original['months'],report['completed_at'])!=original:
            raise ValueError('bundle_evidence/changed')
        return report,original['snapshot'],original['months']

    def catalog_stamp(self,bundle,grant):
        self.for_bundle(bundle,grant)
        return self._value[2]


class FreshShelfEvidence:
    """Read-only capture evidence with separately bound current shelf digests.

    This is deliberately not PreflightEvidence: the existing dispatch
    supervisor cannot accept it as proof that the old group baseline matched.
    """
    def __init__(self,bundle,grant,report,snapshot,months,catalog_pairs,shelf_digests,trial_scope):
        if not isinstance(shelf_digests,tuple):raise ValueError('bundle_evidence/fresh_report')
        validate_fresh_report(bundle,report,months,shelf_digests,trial_scope)
        original=baseline(bundle,grant,snapshot,months,report['completed_at'])
        self._value=deepcopy((report,original,catalog_stamp(bundle,catalog_pairs),shelf_digests,trial_scope))
        self._bundle_hash=digest(bundle);self._grant_hash=digest(grant);self._value_hash=digest(self._value)

    def __repr__(self):return '<FreshShelfEvidence private>'

    def for_bundle(self,bundle,grant):
        if (digest(bundle)!=self._bundle_hash or digest(grant)!=self._grant_hash
                or digest(self._value)!=self._value_hash):raise ValueError('bundle_evidence/changed')
        report,original,stamp,shelves,trial_scope=deepcopy(self._value)
        validate_fresh_report(bundle,report,original['months'],shelves,trial_scope)
        if baseline(bundle,grant,original['snapshot'],original['months'],report['completed_at'])!=original:
            raise ValueError('bundle_evidence/changed')
        return report,original['snapshot'],original['months'],stamp,shelves,trial_scope
