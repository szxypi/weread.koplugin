"""Compare one proposed Web request against an independently bound trial plan.

This helper neither communicates with KOReader nor sends HTTP. The caller must
obtain the context from a fresh same-account read and separately verify state.
"""
from secure_ordinary_reconnect_trial import validate_plan
from fetch_weread_epub import weread_e
from verify_position_roundtrip import validate_payload


def validate_body(plan, context, pclts, stage, candidate, *, observed_at=None):
    validate_plan(plan)
    if (stage not in ('enter', 'position', 'restore') or not isinstance(context, dict)
            or not isinstance(context.get('psvts'), str) or not context['psvts']):
        raise ValueError('ordinary_trial/body_context')
    if pclts is None:
        counter = context.get('pclts')
        missing_counter = counter is None or type(counter) is str and counter in ('', '0') or type(counter) is int and counter == 0
        if (stage != 'enter' or not missing_counter or not isinstance(candidate, dict)
                or type(candidate.get('ct')) is not int or not isinstance(candidate.get('pc'), str)
                or not any(candidate['pc'] == weread_e(candidate['ct'] - delta)
                           for delta in range(31) if candidate['ct'] >= delta)):
            raise ValueError('ordinary_trial/body_context')
        pclts = candidate['pc']
    elif not (isinstance(pclts, str) and bool(pclts) or type(pclts) is int and 0 < pclts <= 2**53-1):
        raise ValueError('ordinary_trial/body_context')
    point = plan['baseline' if stage == 'restore' else 'target']
    wire = dict(book_id=point['book_id'], baseline=point, target=None, context=context, pclts=pclts)
    return validate_payload(wire, 'write_enter' if stage == 'enter' else 'write_restore', candidate,
                            observed_at=observed_at)
