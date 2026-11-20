"""Exact mode/enbookread transport after durable claims; no retry or renewal."""
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request,build_opener
from annotation_experiment_model import canonical,digest
from translation_generation import validate,mode_query,generation_body,mode_ack,status
from translation_wire import MAX_WIRE,capture,response,successful_http
from verify_eink_login import BASE,HEADERS,NoRedirect
from verify_eink_renewal import validate_credentials


def send_once(store,receipt,operation,grant,*,current,opener=None):
    if operation not in ('mode','generation') or not callable(current):raise ValueError('translation_dispatch/operation')
    state,observed=store.read()
    if state is None or observed!=receipt:raise ValueError('translation_dispatch/receipt')
    plan=validate(state['plan']);validate_credentials(grant)
    if grant['vid']!=plan['owner'] or digest(grant)!=plan['grant_sha256']:raise ValueError('translation_dispatch/grant')
    if operation=='generation':
        ack=state['acks'][0] if state['acks'] else {}
        if 'wire' not in ack or not successful_http(ack['wire']):raise ValueError('translation_dispatch/mode_wire_required')
        mode_ack(ack['response'],plan)
    headers=dict(HEADERS,vid=grant['vid'],accessToken=grant['accessToken'])
    if operation=='mode':url=BASE+'/trans/pdfepub?'+urlencode(mode_query(plan));body=None
    else:url=BASE+'/en/bookread';body=canonical(generation_body(plan));headers['Content-Type']='application/json'
    request=Request(url,data=body,headers=headers,method='GET' if operation=='mode' else 'POST')
    transport=opener if opener is not None else build_opener(NoRedirect())
    current();claimed=store.claim(receipt,operation);current()
    # urllib never retries here. A transport exception leaves the durable
    # pending claim intact; available HTTP error bodies are captured as facts.
    try:reply=transport.open(request,timeout=20)
    except HTTPError as error:reply=error
    try:wire=capture(reply.code if isinstance(reply,HTTPError) else reply.status,reply.read(MAX_WIRE+1))
    finally:
        try:reply.close()
        except Exception:pass
    raw=response(wire)
    acknowledged=store.acknowledge(claimed,operation,raw,wire=wire)
    if not successful_http(wire):raise ValueError('translation_dispatch/http_unconfirmed')
    parsed=mode_ack(raw,plan) if operation=='mode' else status(raw,plan)
    return acknowledged,parsed
