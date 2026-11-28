#!/usr/bin/env python3
"""Run one isolated native synthetic upload; unknown outcomes are not replayed."""
import json,os,re,resource,secrets,subprocess,time
from native_personal_upload_trial import Journal
from personal_upload_trial import check,hash_value,prepare,valid_book
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE,NativeProbe
from verify_personal_upload_trial import acknowledged,readback

BODY=b'Synthetic upload for KOReader.\n'


class Probe:
    def __init__(self,journal,grant_check,transport=None):
        self.journal,self.grant_check=journal,grant_check;self.transport=transport or NativeProbe()
        self.reads=0;self.cleanups=0
    def shelf(self,credentials):
        if self.reads>=20:raise ValueError('native_upload/scope')
        self.reads+=1;return self.transport.request('shelf',BASE+'/shelf/sync',credentials=credentials)
    def cleanup(self,credentials,receipt):
        state,current=self.journal.read()
        if (not state or state['phase']!='cleanup_pending' or current!=receipt or self.cleanups
                or not valid_book(state['target']) or state['plan']['owner']!=credentials.get('vid')
                or state['plan']['grant_sha256']!=hash_value(credentials) or not self.grant_check(credentials)):
            raise ValueError('native_upload/scope')
        self.cleanups+=1
        return self.transport.request('cleanup',BASE+'/shelf/delete',body=dict(bookIds=[state['target']],albumIds=[],archiveIds=[]),credentials=credentials)


def native_run(plan,credentials):
    """Only the Docker child sees the grant and synthetic name, through stdin."""
    root='/dev/shm/weread-native-upload-'+secrets.token_hex(12)
    args=['docker','exec','-i','-w','/validation/runtime/lib/koreader','-e','LD_LIBRARY_PATH=./libs',
          '-e','SDL_VIDEODRIVER=dummy','-e','WEREAD_UPLOAD_PROBE_ROOT='+root,'weread-validation',
          'sh','-c','ulimit -c 0; exec timeout --signal=TERM --kill-after=5 150 ./luajit /source/spec/koreader/personal_upload_owner_probe.lua /source']
    payload=json.dumps(dict(name=plan['name'],credentials=credentials),separators=(',',':'))+'\n'
    try:
        completed=subprocess.run(args,input=payload,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=180,check=False)
        frames=[line[len('WEREAD_UPLOAD_PROBE='):] for line in completed.stdout.splitlines() if line.startswith('WEREAD_UPLOAD_PROBE=')]
        if completed.returncode or len(frames)!=1 or len(frames[0])>4096:raise ValueError('native_upload/child')
        result=json.loads(frames[0])
        if (not isinstance(result,dict) or set(result)!={'kind','counts','target'} or result['kind']!='confirmed'
                or not valid_book(result['target']) or not isinstance(result['counts'],dict)
                or set(result['counts'])!={'shelf','credential','put','notify','denied'}
                or any(type(v) is not int for v in result['counts'].values()) or not 2<=result['counts']['shelf']<=6
                or any(result['counts'][k]!=1 for k in ('credential','put','notify')) or result['counts']['denied']!=0):
            raise ValueError('native_upload/child')
        return result
    finally:
        # The path is locally generated and constrained to a disposable tmpfs directory.
        if re.fullmatch(r'/dev/shm/weread-native-upload-[a-f0-9]{24}',root):
            subprocess.run(['docker','exec','weread-validation','rm','-rf','--',root],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15,check=False)


def run(probe,journal,credentials,grant_check,spawn=native_run,*,apply=False,sleep=time.sleep):
    report=dict(result='UNVERIFIED',phase='preflight',native_dispatched=False,cleanup_posts=0,authentication_posts=0)
    try:
        baseline=probe.shelf(credentials);name='KOReaderSynthetic-'+secrets.token_hex(8)+'.txt'
        plan=prepare(credentials,baseline,name,BODY);check(plan,credentials,probe.shelf(credentials))
        if not grant_check(credentials):raise ValueError('native_upload/grant')
        if journal.read()[0] is not None:raise ValueError('native_upload/already_reserved')
        report['independent_baselines_match']=True
        if not apply:report.update(result='READ_ONLY_PREVIEW',phase='preview');return report
        receipt=journal.reserve(plan);report['phase']='reserved';check(plan,credentials,probe.shelf(credentials))
        if not grant_check(credentials):raise ValueError('native_upload/grant')
        receipt=journal.advance(receipt,'launched');report.update(phase='launched',native_dispatched=True)
        result=spawn(plan,credentials);target=result['target']
        if not valid_book(target):raise ValueError('native_upload/target')
        check(plan,credentials,baseline,target,False)
        if not readback(probe,credentials,plan,target,True,5,sleep):raise ValueError('native_upload/import_unconfirmed')
        receipt=journal.advance(receipt,'imported',target=target);report.update(phase='imported',import_observed=True)
        check(plan,credentials,probe.shelf(credentials),target,True)
        receipt=journal.advance(receipt,'cleanup_pending');report['phase']='cleanup_pending'
        ack=False
        try:ack=acknowledged(probe.cleanup(credentials,receipt))
        except Exception:pass
        finally:report['cleanup_posts']=probe.cleanups
        restored=readback(probe,credentials,plan,target,False,3 if ack else 1,sleep)
        report.update(cleanup_acknowledged=ack,restore_observed=restored)
        if not ack or not restored:raise ValueError('native_upload/cleanup_unconfirmed')
        check(plan,credentials,probe.shelf(credentials),target,False)
        if not grant_check(credentials):raise ValueError('native_upload/grant')
        journal.advance(receipt,'restored');report.update(result='NATIVE_SYNTHETIC_ROUNDTRIP_VERIFIED',phase='restored',native_counts=result['counts'])
    except Exception as error:
        allowed={'native_upload/grant','native_upload/already_reserved','native_upload/target','native_upload/child',
                 'native_upload/import_unconfirmed','native_upload/cleanup_unconfirmed'}
        report['reason']=str(error) if str(error) in allowed else 'native_upload/unavailable'
    return report


def main():
    import argparse
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args()
    if args.apply and not args.saved_session:parser.error('--apply requires --saved-session')
    if not args.saved_session:print(json.dumps(dict(result='OFFLINE_ONLY')));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        saved=SessionStore().load();native=NativeSessionStore();grant=native.load(saved['vid']);journal=Journal()
        def same(value):return native.load(saved['vid'])==value
        report=run(Probe(journal,same),journal,grant,same,apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',reason='native_upload/unavailable')
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report,indent=2));return 0 if report['result'] in ('READ_ONLY_PREVIEW','NATIVE_SYNTHETIC_ROUNDTRIP_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
