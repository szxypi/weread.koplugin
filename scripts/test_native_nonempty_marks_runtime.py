#!/usr/bin/env python3
"""Closed synthetic four-step executor, native UI and independent host reads."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit
from mock_weread import MockServer
from native_highlight_mock import Server,Opener,Web,credentials
from secure_highlight_trial import HighlightTrialStore
from selection_trial_probe import SelectionProbe
from test_secure_native_session import Backend
from verify_annotation_experiment import AnnotationProbe
from verify_eink_login import NativeProbe
from verify_highlight_trial import HighlightProbe
from verify_native_mark_style_trial import run,TrialFailure
from verify_nonempty_marks_trial import NonemptyMarksProbe
from secure_nonempty_marks_trial import NonemptyMarksStore

CASES=('normal','lost-ack','no-create','no-color','no-style','no-delete','changed-original','host-loss','host-mismatch','host-lag','dry-run')


class ColorStyleServer(Server):
    def route(self,method,target,data):
        p=urlsplit(target)
        if p.hostname=='i.weread.qq.com' and method=='POST' and p.path in ('/book/addBookmark','/book/updateBookmark','/book/removeBookmark'):
            if len(self.posts)>=4:self.trial_denied+=1;raise ValueError('color/style trial bound')
            expected=['/book/addBookmark','/book/updateBookmark','/book/updateBookmark','/book/removeBookmark'][len(self.posts)]
            if p.path!=expected:self.trial_denied+=1;raise ValueError('color/style trial sequence')
            if p.path=='/book/updateBookmark' and (not self.mark or data!={'bookmarkId':self.mark['bookmarkId'],'style':1 if len(self.posts)==1 else 2,'colorStyle':3}):
                self.trial_denied+=1;raise ValueError('color/style trial target')
            if p.path=='/book/removeBookmark' and (not self.mark or data!={'bookmarkIds':[self.mark['bookmarkId']]}):
                self.trial_denied+=1;raise ValueError('color/style trial target')
            fail=(self.case=='no-create' and len(self.posts)==0 or self.case=='no-color' and len(self.posts)==1 or self.case=='no-style' and len(self.posts)==2 or self.case=='no-delete' and len(self.posts)==3)
            self.control['selection_thought_mode']='no_change' if fail else 'empty' if self.case=='lost-ack' else 'plain'
            old=set(self.selection_marks);result=MockServer.route(self,method,target,data);self.posts.append(p.path)
            if p.path=='/book/addBookmark':
                added=set(self.selection_marks)-old;self.mark=deepcopy(self.selection_marks[next(iter(added))]) if added else None;self.chapter_added=True
                if self.case=='changed-original':self.old_mark['markText']='Other device edit'
            elif p.path=='/book/updateBookmark':self.mark=deepcopy(self.selection_marks[self.mark['bookmarkId']])
            elif not fail:self.mark=None
            return result
        return super().route(method,target,data)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--case',choices=CASES,default='normal');parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167);args=parser.parse_args()
    profiles=set(Path('/dev/shm').glob('weread-reading-*'));report=dict(result='UNVERIFIED',case=args.case)
    with ColorStyleServer(args.case) as server:
        source=SelectionProbe(Web(server),AnnotationProbe(Opener(server),sleep=lambda _n:None),NativeProbe(Opener(server)),sleep=lambda _n:None)
        highlight=HighlightProbe(source,HighlightTrialStore(Backend()),sleep=lambda _n:None)
        probe=NonemptyMarksProbe(highlight,NonemptyMarksStore(Backend()));probe.prepare(dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock_key')),credentials(),select_existing=False)
        if args.case in ('host-loss','host-mismatch'):
            def conflict(*_args,**_kwargs):
                if args.case=='host-loss':raise KeyboardInterrupt()
                raise ValueError('synthetic host mismatch')
            probe.read=conflict
        if args.case=='host-lag':
            observe=source.notes.observe;lag=[]
            def delayed(grant,stage):
                value=observe(grant,stage)
                if stage=='nonempty_marks_readback' and len(server.posts)==2 and not lag:
                    lag.append(True);value['marks']['updated'][probe.target['id']]['colorStyle']=0
                return value
            source.notes.observe=delayed
        command=[sys.executable,str(Path(__file__).with_name('run_native_selection_trial.py')),'--highlight-color-style','--koreader',str(args.koreader),
            '--candidate',str(args.candidate),'--mock-port',str(server.server_port),'--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi)]
        armed=args.case!='dry-run'
        if armed:command.append('--armed')
        try:
            result=run(probe,credentials(),command,armed=armed,mock_port=server.server_port,color_style=True)
            assert args.case in ('normal','lost-ack','host-lag','dry-run');report['execution']=result
        except TrialFailure as error:
            assert args.case in ('no-create','no-color','no-style','no-delete','changed-original','host-loss','host-mismatch'),error.runner
            state,_receipt=probe.store.read();assert state['phase'] in ('create_pending','color_pending','style_pending','delete_pending') and state['reserved_posts']==4
            if error.runner is not None:assert error.runner['profile_removed']
            before=len(server.posts)
            try:run(probe,credentials(),command,armed=True,mock_port=server.server_port,color_style=True)
            except ValueError:pass
            else:raise AssertionError('pending native styles replayed')
            assert len(server.posts)==before;report.update(expected_stop=True,pending_replay_blocked=True,native_ui=error.runner)
        assert set(Path('/dev/shm').glob('weread-reading-*'))==profiles
        for process in Path('/proc').iterdir():
            if not process.name.isdecimal():continue
            try:parts=(process/'cmdline').read_bytes().split(b'\0')
            except (OSError,ProcessLookupError):continue
            assert not any(part.endswith(b'/spec/koreader/owner_reading_probe.lua') for part in parts)
        state,_receipt=probe.store.read()
        report.update(result='PASS',mock_data_posts=len(server.posts),native_denied=server.trial_denied,intent_state=state['phase'] if state else 'absent',profile_removed=True,workers_reaped=True,real_account_data_posts=0)
        assert not server.trial_denied
    print(json.dumps(report,ensure_ascii=False,indent=2));return 0


if __name__=='__main__':raise SystemExit(main())
