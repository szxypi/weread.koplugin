"""One-shot native public-account subscription with host-gated readbacks."""
import secrets,subprocess,tempfile
from pathlib import Path
from mp_subscription_trial import Journal as BaseJournal,check,prepare,valid_id
from native_trial_pipe import Frames,reply,stop,write_initial
from run_native_mp_subscription_ui import validate_stage
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain

SERVICE='org.codex.weread.goal-native-mp-subscription-ui-v1'


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-native-mp-subscription-ui-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock)


def execute(plan,credentials,review,armed,on_step,command,*,mock_port=None):
    if type(armed) is not bool or not command or any(not isinstance(x,str) or not x for x in command):raise ValueError('native_mp_ui/command')
    token=secrets.token_hex(16)
    payload=dict(credentials=credentials,account_id=plan['account_id'],review_id=review,shelf_books=plan['count'],
        members_digest=plan['members_sha256'],rpc_token=token,permit_writes=armed)
    if mock_port is not None:payload['mock_port']=mock_port
    child=None;steps=0
    try:
        child=subprocess.Popen(command+(['--armed'] if armed else []),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=240)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':result=value;break
            if not armed or value!={'seq':steps+1} or steps>=2:raise ValueError('native_mp_ui/step')
            on_step(steps+1);steps+=1;reply(child.stdin,dict(seq=steps,ok=True))
        if (child.wait(timeout=15) or steps!=(2 if armed else 0) or not isinstance(result,dict)
                or set(result)!={'result','profile_removed','installed','stage'} or result['result']!='PASS' or result['profile_removed'] is not True
                or not isinstance(result['installed'],dict) or set(result['installed'])!={'files','bytes_match'}
                or type(result['installed']['files']) is not int or not 1<=result['installed']['files']<=1000
                or result['installed']['bytes_match'] is not True):raise ValueError('native_mp_ui/child')
        return validate_stage(result['stage'],armed)
    finally:
        if child is not None:stop(child)
        payload.clear()


def run(probe,journal,credentials,target,review,grant_check,runner,*,apply=False):
    report=dict(result='UNVERIFIED',phase='preflight',native_dispatched=False,account_data_posts=None,authentication_posts=0,independent_steps=0)
    receipt=None
    try:
        if not valid_id(target) or not isinstance(review,str) or not review.startswith(target+'_'):raise ValueError('native_mp_ui/target')
        baseline=probe.shelf(credentials);plan=prepare(credentials,baseline,target);check(plan,credentials,probe.shelf(credentials),False)
        if not grant_check(credentials):raise ValueError('native_mp_ui/grant')
        if journal.read()[0] is not None:raise ValueError('native_mp_ui/already_reserved')
        report['independent_baselines_match']=True
        preview=runner(plan,credentials,review,False,lambda _seq:(_ for _ in ()).throw(ValueError('native_mp_ui/step')))
        validate_stage(preview,False);check(plan,credentials,probe.shelf(credentials),False)
        if not grant_check(credentials):raise ValueError('native_mp_ui/grant')
        report['same_plan_zero_write_preview']=True
        if not apply:report.update(result='READ_ONLY_PREVIEW',phase='preview',account_data_posts=0);return report
        receipt=journal.reserve(plan);report['phase']='prepared';check(plan,credentials,probe.shelf(credentials),False)
        if not grant_check(credentials):raise ValueError('native_mp_ui/grant')
        receipt=journal.advance(receipt,'add_pending');report.update(phase='add_pending',native_dispatched=True)
        def on_step(seq):
            nonlocal receipt
            state,current=journal.read()
            if state is None or current!=receipt or state['plan']!=plan or state['phase']!=('add_pending' if seq==1 else 'remove_pending'):
                raise ValueError('native_mp_ui/ownership')
            if not grant_check(credentials):raise ValueError('native_mp_ui/grant')
            check(plan,credentials,probe.shelf(credentials),seq==1);report['independent_steps']=seq
            if seq==1:
                receipt=journal.advance(receipt,'add_confirmed');report['phase']='add_confirmed'
                check(plan,credentials,probe.shelf(credentials),True)
                if not grant_check(credentials):raise ValueError('native_mp_ui/grant')
                receipt=journal.advance(receipt,'remove_pending');report['phase']='remove_pending'
        stage=runner(plan,credentials,review,True,on_step);validate_stage(stage,True)
        if report['independent_steps']!=2:raise ValueError('native_mp_ui/step')
        check(plan,credentials,probe.shelf(credentials),False)
        if not grant_check(credentials):raise ValueError('native_mp_ui/grant')
        journal.advance(receipt,'restored')
        report.update(result='NATIVE_MP_UI_ROUNDTRIP_VERIFIED',phase='restored',account_data_posts=2,
            original_members_flags_groups_restored=True,native_counts=dict(shelf=stage['native_gets'],add=stage['adds'],remove=stage['removes']))
    except Exception as error:
        known={'native_mp_ui/target','native_mp_ui/grant','native_mp_ui/already_reserved','native_mp_ui/step','native_mp_ui/ownership','native_mp_ui/child'}
        report['reason']=str(error) if str(error) in known else 'native_mp_ui/unavailable'
        if not report['native_dispatched']:report['account_data_posts']=0
    return report
