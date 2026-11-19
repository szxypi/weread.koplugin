#!/usr/bin/env python3
"""Native TXT bookmark roundtrip with independently scoped Web readback.

Offline by default. A fresh one-shot synthetic fixture is required. Only its
newly created bookmark may be removed; Web observations are GET-only and
cannot authorize, repeat or change either native write.
"""
import argparse
import base64
import json
from pathlib import Path
import resource
import tempfile
from urllib.parse import urlencode

from cb_official_viewport import allowed_bookmark_read
import cb_txt_padded_bookmark_trial as trial
from personal_upload_trial import Journal
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_cb_fixture_bookmark_native import run as run_bookmark,run_ui
from verify_cb_metadata import valid_errors
from verify_cb_txt_fixture import Receipt
import verify_cb_txt_padded_bookmark_native as fixture
from verify_web_source_progress import BASE,WebSourceProbe


def stores():
    def backend(part):return MacKeychain(service='org.codex.weread.cb-txt-bookmark-cross-channel-'+part+'-v1',account=ACCOUNT)
    def lock(part):
        path=Path(tempfile.gettempdir())/('codex-cb-txt-bookmark-cross-channel-'+part+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return (Journal(backend=backend('upload'),lock=lock('upload'),validator=fixture.validate_plan),
            Receipt(backend=backend('receipt')),trial.Intent(backend=backend('intent'),lock=lock('intent')))


class BookmarkWeb(WebSourceProbe):
    def __init__(self,book):super().__init__();self.book_id=book;self.reads=0
    def guard(self,stage,url,body):
        if stage in ('bookmarks_before','bookmarks_after'):
            if (not self.authenticated or self.reads>=2 or not allowed_bookmark_read('GET',url,body,self.book_id)):
                raise ValueError('txt_bookmark_web/scope')
            self.reads+=1;return
        return super().guard(stage,url,body)


def compare(value,book,body,target):
    valid_errors(value)
    if (not isinstance(value.get('updated'),list) or len(value['updated'])>5000
            or value.get('bookId') not in (None,book) or value.get('hasMore') not in (None,False,0)):
        raise ValueError('txt_bookmark_web/schema')
    rows=[row for row in value['updated'] if isinstance(row,dict) and row.get('bookmarkId')==target['id']]
    if len(rows)!=1:raise ValueError('txt_bookmark_web/missing')
    row=rows[0];text=row.get('markText');decoded=None
    if isinstance(text,str):
        try:decoded=base64.b64decode(text,validate=True).decode('utf-8')
        except (ValueError,UnicodeError):pass
    return dict(single_new_record=len(value['updated'])==1,point_type=type(row.get('type')) is int and row['type']==0,
                chapter_matches=type(row.get('chapterUid')) is int and row['chapterUid']==body['chapterUid'],
                range_matches=row.get('range')==body['range'],preview_matches=text==body['markText'] or decoded==body['markText'])


def observe_web(payload,body,target,*,factory=BookmarkWeb):
    if (not isinstance(payload,dict) or not isinstance(target,dict) or set(target)!={'id','sha256'}
            or payload.get('book')!=body.get('bookId') or payload.get('owner')!=payload.get('cookies',{}).get('wr_vid')
            or fixture.point(payload.get('source'),payload['book'],payload['chapter'],body)['chapter_offset']!=payload.get('first')):
        raise ValueError('txt_bookmark_web/scope')
    web=factory(payload['book']);web.vid=payload['owner']
    try:
        for key,value in payload['cookies'].items():web.set_cookie(key,value)
        web.verify_account();url=BASE+'/web/book/bookmarklist?'+urlencode(dict(bookId=payload['book']))
        first=compare(web.request('bookmarks_before',url),payload['book'],body,target)
        second=compare(web.request('bookmarks_after',url),payload['book'],body,target);web.verify_account()
        if first!=second:raise ValueError('txt_bookmark_web/changed')
        return dict(result='WEB_READBACK',stable=True,**first)
    finally:web.close()


def run(saved,session,native,grant,journal,receipt,intent,command,*,apply=False,runner=run_bookmark,
        native_ui=run_ui,web_observer=observe_web,uploader=None):
    observations=[]
    def wrapped_ui(*args,armed=False,**kwargs):
        def created(payload,body,target):
            try:
                value=web_observer(payload,body,target)
                fields={'result','stable','single_new_record','point_type','chapter_matches','range_matches','preview_matches'}
                if (not isinstance(value,dict) or set(value)!=fields or value['result']!='WEB_READBACK'
                        or any(type(value[key]) is not bool for key in fields-{'result'})):
                    raise ValueError('txt_bookmark_web/observation')
                observations.append(value)
            except Exception:observations.append(dict(result='UNVERIFIED'))
        return native_ui(*args,armed=armed,on_created=created if armed else None,**kwargs)
    def wrapped_runner(*args,**kwargs):
        kwargs['ui_runner']=wrapped_ui
        return runner(*args,**kwargs)
    options=dict(apply=apply,runner=wrapped_runner)
    if uploader is not None:options['uploader']=uploader
    report=fixture.run(saved,session,native,grant,journal,receipt,intent,command,**options)
    if report.get('result')=='CB_NATIVE_TXT_PADDED_BOOKMARK_VERIFIED':
        valid=(len(observations)==1 and observations[0].get('result')=='WEB_READBACK'
               and all(value is True for key,value in observations[0].items() if key!='result'))
        report['result']='CB_TXT_BOOKMARK_CROSS_CHANNEL_VERIFIED' if valid else 'CB_TXT_BOOKMARK_CROSS_CHANNEL_UNVERIFIED'
        report['web_observation']=observations[0] if len(observations)==1 else dict(result='UNVERIFIED')
        report['official_saved_bookmark_display_verified']=False
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');parser.add_argument('--runner',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.apply and not args.saved_session or args.saved_session and not args.runner or args.runner and not args.saved_session:
        parser.error('saved session and runner required')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',native_writes_allocated=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,session,native,grant,*stores(),args.runner,apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',phase='setup',native_writes_allocated=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report.get('result') not in ('READ_ONLY_PREVIEW','CB_TXT_BOOKMARK_CROSS_CHANNEL_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
