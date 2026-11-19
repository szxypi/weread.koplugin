#!/usr/bin/env python3
"""Read-only E-Ink notebook-list and pagination shape probe.

Offline by default. Book identities, titles, notes and credentials remain in
memory; the report contains only schema flags and bounded counts.
"""
import argparse
import json
import resource
from urllib.parse import urlencode

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from notebook_catalog_model import project
from verify_eink_login import BASE, NativeProbe

FIELDS=('bookId','book','noteCount','reviewCount','bookmarkCount','sort','readingProgress','markedStatus')
BOOK_FIELDS=('bookId','title','author','cover','format')


class Probe(NativeProbe):
    def __init__(self):
        super().__init__();self.calls=0

    def read(self,grant,count,last=None):
        if count not in (2,100) or last is not None and (type(last) is not int or not 0<=last<=2**53-1):
            raise ValueError('notebook/scope')
        query=dict(count=count)
        if last is not None:query['lastSort']=last
        self.calls+=1
        if self.calls>3:raise ValueError('notebook/scope')
        return super().request('notebooks',BASE+'/user/notebooks?'+urlencode(query),credentials=grant)


def summarize(value):
    if not isinstance(value,dict) or not isinstance(value.get('books'),list) or len(value['books'])>5000:
        raise ValueError('notebook/response')
    rows=value['books']
    if any(not isinstance(row,dict) for row in rows):raise ValueError('notebook/response')
    info=dict(rows=len(rows),root_fields={key:type(value[key]).__name__ for key in ('hasMore','totalBookCount','totalNoteCount','synckey') if key in value},
        fields={key:sum(key in row for row in rows) for key in FIELDS},
        book_fields={key:sum(isinstance(row.get('book'),dict) and key in row['book'] for row in rows) for key in BOOK_FIELDS},
        field_types={key:sorted({type(row[key]).__name__ for row in rows if key in row}) for key in FIELDS},
        book_field_types={key:sorted({type(row['book'][key]).__name__ for row in rows
                             if isinstance(row.get('book'),dict) and key in row['book']}) for key in BOOK_FIELDS})
    for key in ('hasMore','totalBookCount','totalNoteCount'):
        if type(value.get(key)) is int and 0<=value[key]<=1000000:info[key]=value[key]
    return info


def identity(row):
    book=row.get('book') if isinstance(row.get('book'),dict) else {}
    return str(row.get('bookId') or book.get('bookId') or '')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,private_values_saved=False)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=probe=None
    try:
        if args.saved_session:
            saved=SessionStore().load();store=NativeSessionStore();grant=store.load(saved['vid']);probe=Probe()
            small=probe.read(grant,2);large=probe.read(grant,100)
            report['small']=summarize(small);report['large']=summarize(large)
            small_ids=[identity(row) for row in small['books']];large_ids=[identity(row) for row in large['books']]
            report['prefix_matches']=bool(small_ids) and small_ids==large_ids[:len(small_ids)]
            report['unique_ids']=all(large_ids) and len(set(large_ids))==len(large_ids)
            report['id_classes']={kind:sum((item.isdigit() if kind=='numeric' else item.startswith('CB_') if kind=='imported'
                                            else not item.isdigit() and not item.startswith('CB_')) for item in large_ids)
                                  for kind in ('numeric','imported','other')}
            report['book_id_pairs_match']=all(str(row.get('bookId'))==str(row.get('book',{}).get('bookId')) for row in large['books'])
            report['counts_nonnegative_integers']=all(type(row.get(k)) is int and row[k]>=0 for row in large['books']
                                                      for k in ('noteCount','reviewCount','bookmarkCount'))
            report['complete_projection_verified']=len(project(large,1)['books'])==len(large_ids)
            if len(small['books'])==2 and type(small['books'][-1].get('sort')) is int:
                later=probe.read(grant,2,small['books'][-1]['sort']);report['next']=summarize(later)
                later_ids=[identity(row) for row in later['books']]
                report['next_matches_large_slice']=later_ids==large_ids[2:2+len(later_ids)] and bool(later_ids)
                report['next_disjoint']=not set(small_ids)&set(later_ids)
            if store.load(saved['vid'])!=grant:raise ValueError('notebook/stale')
            report['result']='OBSERVED'
    except Exception:
        report.update(result='UNVERIFIED',reason='notebook_read_unavailable')
    finally:
        if probe:report['stages']=[{k:v for k,v in row.items() if k in ('stage','status','error_code')} for row in probe.report['stages']]
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['result'] in ('OFFLINE_ONLY','OBSERVED') else 1


if __name__=='__main__':raise SystemExit(main())
