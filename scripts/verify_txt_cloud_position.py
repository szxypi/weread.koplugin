#!/usr/bin/env python3
"""Read-only TXT cloud coordinate preflight. Raw data remains in memory."""
import argparse
from datetime import datetime,timezone
import json
import resource
from urllib.parse import urlencode
from fetch_weread_epub import normalize_chapter_infos
from secure_weread_session import SessionStore
from verify_txt_reading import TxtProbe,select_chapter
from verify_reader_progress import project as point
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,PreflightError
from txt_cloud_position import prepare


class UnstartedTxt(ValueError):pass


class Probe(TxtProbe):
    def __init__(self):
        super().__init__();self.unstarted_txt=0

    def inspect_book(self,book_id,hint=None):
        try:return super().inspect_book(book_id,hint)
        except UnstartedTxt:
            self.unstarted_txt+=1;self.sample=None;return False

    def choose_chapter(self,chapters):
        self.raw_progress=self.request('progress_before',BASE+'/web/book/getProgress?'+urlencode(dict(bookId=self.book_id)))
        self.before=point(self.raw_progress,self.book_id)
        preferred=str(self.before.get('chapter_uid',''))
        if preferred=='0':raise UnstartedTxt('txt_cloud/unstarted')
        return select_chapter(chapters,preferred)

    def inspect_plan(self):
        sample=self.sample
        later,chapters=normalize_chapter_infos(self.request('catalog_after',BASE+'/web/book/chapterInfos',dict(bookIds=[self.book_id])),self.book_id)
        after=self.request('progress_after',BASE+'/web/book/getProgress?'+urlencode(dict(bookId=self.book_id)))
        if chapters!=sample['chapters'] or later!=sample['record'] or point(after,self.book_id)!=self.before:raise ValueError('txt_cloud/changed')
        return prepare(sample['plain'],self.raw_progress,sample['context'],chapters,self.book_id)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,
        private_data_on_regular_disk=False,upload_enabled=False)
    web=saved=None
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            store=SessionStore();saved=store.load();web=Probe();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            if not web.find_sample(limit=16):
                report.update(result='NO_RESTORABLE_TXT_IN_BOUNDED_SAMPLE',catalogs_checked=web.catalog_count,unstarted_txt=web.unstarted_txt,
                    catalog_format_counts=web.format_counts,cloud_coordinate_semantics_verified=False)
                raise UnstartedTxt('txt_cloud/no_restorable_sample')
            report.update(txt_source_observed=True,started_position=str(web.before.get('chapter_uid'))!='0',source_bytes=len(web.sample['plain'].encode()))
            plan=web.inspect_plan()
            report.update(result='TXT_CLOUD_POINT_READ_VERIFIED',source_coordinate_basis=plan['basis'],source_summary_matches=plan['source_summary_matches'],
                original_summary_preserved=plan['original_summary_preserved'],
                **{key:plan[key] for key in ('source_summary_present','source_summary_nonempty','existing_wire_preflight_compatible','source_has_bom','source_crlf_pairs','source_nonbmp_scalars','source_summary_scalars','source_summary_nonspace_scalars','summary_unique_start_matches','summary_unique_end_matches')},adjacent_single_unit_target=plan['target'] is not None,
                cloud_coordinate_semantics_verified=False,reader_and_independent_progress_match=True,source_catalog_and_progress_unchanged=True)
    except UnstartedTxt:pass
    except Exception:
        report['result']='UNVERIFIED'
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(store,saved,web)
                except Exception:report['result']='UNVERIFIED'
            report.update(catalogs_checked=web.catalog_count,unstarted_txt_skipped=web.unstarted_txt,catalog_format_counts=web.format_counts)
            report['stages']=[{key:row[key] for key in ('stage','status') if key in row} for row in web.report['stages']]
            web.sample=None;web.close()
        if saved:saved.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
