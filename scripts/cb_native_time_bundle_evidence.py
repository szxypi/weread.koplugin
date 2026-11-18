"""Immutable in-memory CB cross-day preflight; no transport or send authority."""
from copy import deepcopy

from annotation_experiment_model import digest
from cb_native_time_bundle_accounting import baseline
from fetch_weread_epub import normalize_chapter_infos
from readtime_upload_model import integer
from source_currentness import catalog


def catalog_check(payload,plan):
    index,stamp=catalog(payload,plan['book_id'],plan['chapter_uid'],imported=True)
    record,_rows=normalize_chapter_infos(payload,plan['book_id']);book=record.get('book')
    nodes=(record,book if isinstance(book,dict) else {})
    versions=[node[key] for node in nodes for key in ('bookVersion','version') if key in node]
    if (not versions or any(not integer(item,1,2147483647) or item!=plan['book_version'] for item in versions)
            or index!=plan['chapter_idx']):raise ValueError('cb_evidence/catalog')
    return index,stamp


class PreflightEvidence:
    def __init__(self,bundle,grant,report,snapshot,months,catalog_pairs):
        flags=('exact_capture_and_source_bound','both_positions_counts_source_shelves_exact',
               'two_statistics_reads_stable','server_clock_after_boundary')
        fields=set(flags)|{'result','seconds','observed_months','completed_at','account_data_posts',
                           'authentication_posts','historical_accounting_verified','dispatch_capability'}
        if (not isinstance(report,dict) or set(report)!=fields or report['result']!='CB_CROSS_DAY_READONLY_VERIFIED'
                or any(report[key] is not True for key in flags) or type(report['seconds']) is not int
                or report['seconds']!=bundle['plan']['seconds'] or not integer(report['completed_at'],bundle['plan']['not_before'],4102444800)
                or type(report['observed_months']) is not int or report['observed_months']!=len(months)
                or any(type(report[key]) is not int or report[key]!=0 for key in ('account_data_posts','authentication_posts'))
                or report['historical_accounting_verified'] is not False or report['dispatch_capability'] is not False):
            raise ValueError('cb_evidence/report')
        original=baseline(bundle,grant,snapshot,months,report['completed_at'])
        if (not isinstance(catalog_pairs,list) or len(catalog_pairs)!=2
                or any(not isinstance(pair,list) or len(pair)!=2 for pair in catalog_pairs)):
            raise ValueError('cb_evidence/catalog')
        try:checks=[catalog_check(payload,bundle['plan']) for pair in catalog_pairs for payload in pair]
        except (ValueError,TypeError,KeyError,StopIteration):raise ValueError('cb_evidence/catalog') from None
        if any(value!=checks[0] for value in checks[1:]):raise ValueError('cb_evidence/catalog')
        self._value=deepcopy((report,original,checks[0][1]));self._bundle_hash=digest(bundle);self._grant_hash=digest(grant)
        self._value_hash=digest(self._value)
    def __repr__(self):return '<CBPreflightEvidence private>'
    def for_bundle(self,bundle,grant):
        if (digest(bundle)!=self._bundle_hash or digest(grant)!=self._grant_hash
                or digest(self._value)!=self._value_hash):raise ValueError('cb_evidence/changed')
        report,original,_stamp=deepcopy(self._value)
        if baseline(bundle,grant,original['snapshot'],original['months'],report['completed_at'])!=original:
            raise ValueError('cb_evidence/changed')
        return report,original['snapshot'],original['months']
    def catalog_stamp(self,bundle,grant):
        self.for_bundle(bundle,grant);return self._value[2]
