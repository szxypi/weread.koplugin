#!/usr/bin/env python3
"""Offline native note rendering. Input and logs stay in memory; files in tmpfs."""
import argparse
import json
import os
from pathlib import Path
import resource
import re
from html.parser import HTMLParser
import subprocess
import sys
import tempfile
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate,run_child
from verify_owner_footnotes import FRAME,LIMIT,decode_result,projected_catalog


def validate_payload(value):
    if not isinstance(value,dict) or set(value)!={'chapters','samples'}:raise ValueError('input_invalid')
    chapters=projected_catalog(value['chapters'])
    if chapters!=value['chapters']:raise ValueError('input_invalid')
    samples=value['samples'];uids={str(row['chapterUid']) for row in chapters};seen=set()
    if not isinstance(samples,list) or not 1<=len(samples)<=4:raise ValueError('input_invalid')
    for sample in samples:
        if not isinstance(sample,dict) or set(sample)!={'uid','html','expected_notes'}:raise ValueError('input_invalid')
        uid=sample['uid']
        if not isinstance(uid,str) or uid not in uids or uid in seen or not isinstance(sample['html'],str):raise ValueError('input_invalid')
        if not isinstance(sample['expected_notes'],list) or any(not isinstance(note,str) for note in sample['expected_notes']):raise ValueError('input_invalid')
        seen.add(uid)
    return value


class PopupText(HTMLParser):
    def __init__(self):super().__init__(convert_charrefs=True);self.parts=[];self.skip=0
    def handle_starttag(self,tag,attrs):
        if tag in ('head','style','script'):self.skip+=1
    def handle_endtag(self,tag):
        if tag in ('head','style','script'):self.skip=max(0,self.skip-1)
    def handle_data(self,value):
        if not self.skip:self.parts.append(value)


def verify_native_text(value,payload):
    pairs=value.pop('_native_private',None)
    expected_total=sum(len(sample.get('expected_notes',[])) for sample in payload['samples'])
    if pairs=={} and expected_total==0:pairs=[]
    if not isinstance(pairs,list):raise ValueError('private_envelope_invalid')
    seen=set()
    for pair in pairs:
        if not isinstance(pair,dict) or set(pair)!={'sample_index','note_index','html'}:raise ValueError('private_envelope_invalid')
        sample,note=pair['sample_index'],pair['note_index']
        if type(sample) is not int or type(note) is not int or not 1<=sample<=len(payload['samples']):raise ValueError('private_envelope_invalid')
        notes=payload['samples'][sample-1].get('expected_notes',[])
        if not 1<=note<=len(notes) or (sample,note) in seen or not isinstance(pair['html'],str):raise ValueError('private_envelope_invalid')
        seen.add((sample,note));parser=PopupText();parser.feed(pair['html'])
        text=re.sub(r'[ \t\n\r\f\v]','',''.join(parser.parts));expected=re.sub(r'[ \t\n\r\f\v]','',notes[note-1])
        value['native_expected_nbsp']+=expected.count('\xa0')
        value['native_expected_zwsp']+=expected.count('\u200b');value['native_expected_zwnj']+=expected.count('\u200c');value['native_expected_zwj']+=expected.count('\u200d')
        value['native_actual_nbsp']+=text.count('\xa0')
        normalized_text=re.sub(r'\s+','',text);normalized_expected=re.sub(r'\s+','',expected)
        if normalized_expected and normalized_expected in normalized_text and expected not in text:value['native_whitespace_normalizations']+=1
        value['native_actual_soft_hyphens']+=text.count('\xad');value['native_expected_soft_hyphens']+=expected.count('\xad')
        lexical_text=normalized_text.replace('\xad','');lexical_expected=normalized_expected.replace('\xad','')
        if lexical_expected and lexical_expected in lexical_text and normalized_expected not in normalized_text:value['native_hyphenation_normalizations']+=1
        if not lexical_expected or lexical_expected not in lexical_text:
            value['native_error_code']=5;value['native_expected_bytes']=len(expected.encode());value['native_actual_bytes']=len(text.encode())
    if len(pairs)!=expected_total and not value['native_error_code']:value['native_error_code']=96
    return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    assert sys.platform=='linux' and any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())
    assert min(args.width,args.height,args.dpi)>0
    report=None;root=None
    try:
        raw=sys.stdin.buffer.read(LIMIT+1)
        if len(raw)>LIMIT:raise ValueError('input_limit')
        payload=validate_payload(json.loads(raw))
        with tempfile.TemporaryDirectory(prefix='weread-notes-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';xdg=root/'xdg';(profile/'plugins').mkdir(parents=True);xdg.mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins');check_installed(args.candidate,profile)
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            script=Path(__file__).resolve().parent.parent/'spec/koreader/probe_owner_footnote_links.lua'
            command=[str(args.koreader.resolve()/'luajit'),str(script),str(profile/'plugins/weread.koplugin'),'native']
            # Native cases live outside the distributable plugin.
            env['WEREAD_NOTE_CASE']=str(script.with_name('owner_footnote_native_case.lua'))
            status,out,repaint=run_child(command,env,raw,cwd=args.koreader.resolve(),timeout=180)
            if status or repaint:raise ValueError('native_failed')
            if len(out)>LIMIT or out.count(FRAME)!=1:raise ValueError('private_envelope_invalid')
            value=json.loads(out.split(FRAME,1)[1]);verify_native_text(value,payload)
            report=decode_result(FRAME+json.dumps(value).encode(),payload)
            if report['valid_converted_chapters']!=len(payload['samples']) or report['native_plugin_checks']!=report['native_opened_chapters']:raise ValueError('native_scope_invalid')
        if root.exists():raise ValueError('profile_cleanup_failed')
        if report['native_error_code']:
            print(json.dumps(dict(result='FAILED',reason='native_note_mismatch',profile_removed=True,
                counters=report)));return 1
        print((FRAME+json.dumps(report).encode()).decode())
        return 0
    except Exception:
        # No native traceback, private stderr, note text or input is forwarded.
        print(json.dumps(dict(result='FAILED',reason='native_probe_failed',profile_removed=root is not None and not root.exists())))
        return 1


if __name__=='__main__':raise SystemExit(main())
