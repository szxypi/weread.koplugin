#!/usr/bin/env python3
"""Read-only E-Ink notebook-list and pagination shape probe.

Offline by default. Book identities, titles, notes and credentials remain in
memory; the report contains only schema flags and bounded counts.
"""
import argparse
import json
import resource
import subprocess
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
        if self.calls>4:raise ValueError('notebook/scope')
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
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-ui',action='store_true')
    parser.add_argument('--cached-notes-sample',action='store_true',help='Also check real saved-note samples in the isolated UI')
    parser.add_argument('--bulk-notes',action='store_true',help='Verify the native batch-save menu and offline cache')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.native_ui and (not args.saved_session or not args.lua_command) or args.lua_command and not args.native_ui:
        parser.error('native UI requires saved session and Lua command')
    if args.cached_notes_sample and not args.native_ui:parser.error('cached note samples require native UI')
    if args.bulk_notes and (not args.native_ui or args.cached_notes_sample):parser.error('bulk notes require native UI and exclude cached samples')
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
            if len(large['books'])>1 and type(large['books'][0].get('sort')) is int:
                after_first=probe.read(grant,100,large['books'][0]['sort']);report['after_first']=summarize(after_first)
                after_ids=[identity(row) for row in after_first['books']]
                report['after_first_matches_full']=after_ids==large_ids
                report['after_first_matches_tail']=after_ids==large_ids[1:]
                report['after_first_excludes_cursor']=large_ids[0] not in after_ids
            if store.load(saved['vid'])!=grant:raise ValueError('notebook/stale')
            if args.native_ui:
                now=1;expected=project(large,now)
                payload=dict(source=large,owner=saved['vid'],now=now,credentials=grant)
                if args.bulk_notes:payload['bulk_notes']=True
                if args.cached_notes_sample:
                    from verify_my_cloud_marks import MarksProbe
                    from verify_my_cloud_thoughts import ThoughtsProbe
                    marks,thoughts=MarksProbe(),ThoughtsProbe()
                    marks.prepare(grant);thoughts.prepare(grant)
                    payload['saved_samples']=[dict(kind='marks',snapshot=marks.model),
                                              dict(kind='thoughts',snapshot=thoughts.samples[0]['expected'])]
                    report['sample_snapshots']=2
                child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=1280 if args.bulk_notes else 600)
                from run_notebook_catalog_ui import FRAME,validate_stage
                if len(child.stdout)>12*1024*1024 or child.stdout.count(FRAME)!=1:raise ValueError('notebook/ui_frame')
                actual=json.loads(child.stdout.split(FRAME)[1]);ui=actual.get('ui')
                if isinstance(ui,dict):
                    report['ui_diagnostics']=[{key:row[key] for key in ('failed_line','requests','forbidden','pages','books')
                        if type(row.get(key)) is int and 0<=row[key]<=100000} for row in ui.get('stages',[])[:2] if isinstance(row,dict)]
                    if args.bulk_notes:
                        report['bulk_diagnostics']=[{key:value for key,value in row.get('bulk_notes',{}).items()
                            if key in ('books','saved','skipped','requests') and type(value) is int and 0<=value<=5000
                            or key in ('menu_started','cache_verified') and type(value) is bool}
                            for row in ui.get('stages',[])[:2] if isinstance(row,dict) and isinstance(row.get('bulk_notes'),dict)]
                if child.returncode or actual.get('model')!=expected or actual.get('native')!=expected or actual.get('requests')!=1:
                    raise ValueError('notebook/ui_result')
                if (not isinstance(ui,dict) or set(ui)!={'result','profile_removed','installed_bytes_match','installed_files','stages'}
                        or ui['result']!='PASS' or ui['profile_removed'] is not True or ui['installed_bytes_match'] is not True
                        or type(ui['installed_files']) is not int or not 1<=ui['installed_files']<=1000
                        or not isinstance(ui['stages'],list) or len(ui['stages'])!=2):raise ValueError('notebook/ui_result')
                for row,mode in zip(ui['stages'],('live','reopen')):validate_stage(row,mode,len(expected['books']),bulk_notes=args.bulk_notes)
                if args.bulk_notes:
                    for key in ('books','saved','skipped'):
                        if ui['stages'][0]['bulk_notes'][key]!=ui['stages'][1]['bulk_notes'][key]:raise ValueError('notebook/ui_result')
                if store.load(saved['vid'])!=grant:raise ValueError('notebook/stale')
                report.update(native_https_matches=True,native_ui_verified=True,ui=ui)
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
