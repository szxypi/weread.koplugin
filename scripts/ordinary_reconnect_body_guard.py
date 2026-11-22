"""Compare one proposed Web request against an independently bound trial plan.

This helper neither communicates with KOReader nor sends HTTP. The caller must
obtain the context from a fresh same-account read and separately verify state.
"""
from secure_ordinary_reconnect_trial import validate_plan
from verify_position_roundtrip import validate_payload


def validate_body(plan, context, pclts, stage, candidate, *, observed_at=None):
    validate_plan(plan)
    if (stage not in ('enter', 'position', 'restore') or not isinstance(context, dict)
            or not isinstance(context.get('psvts'), str) or not context['psvts']
            or not isinstance(pclts, str) or not pclts):
        raise ValueError('ordinary_trial/body_context')
    point = plan['baseline' if stage == 'restore' else 'target']
    wire = dict(book_id=point['book_id'], baseline=point, target=None, context=context, pclts=pclts)
    return validate_payload(wire, 'write_enter' if stage == 'enter' else 'write_restore', candidate,
                            observed_at=observed_at)
