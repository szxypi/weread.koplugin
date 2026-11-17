"""Independent original-text and single-chapter catalog proof. No I/O."""
from copy import deepcopy
import re
from annotation_experiment_model import digest,canonical
from verify_translation_preflight import TranslationText,content_summary

TRANSLATION_FIELDS={'hasTranslated','translateVersion','transWordCount'}


def validate_proof(proof,plan):
    fields={'original_text_sha256','translation_fields_before'}
    if (not isinstance(proof,dict) or set(proof) not in (fields,fields|{'baseline'})
            or not isinstance(proof['original_text_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',proof['original_text_sha256'])
            or not isinstance(proof['translation_fields_before'],dict) or not set(proof['translation_fields_before'])<=TRANSLATION_FIELDS):raise ValueError('translation_result/proof')
    fields=proof['translation_fields_before']
    for key,value in fields.items():
        if key=='hasTranslated':valid=type(value) is bool
        else:valid=type(value) is int and 0<=value<=9007199254740991
        if not valid:raise ValueError('translation_result/proof')
    if fields.get('translateVersion',0)!=plan['translate_version']:raise ValueError('translation_result/proof')
    if 'baseline' in proof and (not isinstance(proof['baseline'],dict) or len(canonical(proof['baseline']))>16*1024
            or digest(proof['baseline'])!=plan['baseline_sha256']):raise ValueError('translation_result/proof')
    return deepcopy(proof)


def make_proof(model,plan,original,*,baseline=None):
    if digest(model)!=plan['catalog_sha256']:raise ValueError('translation_result/catalog')
    rows=[r for r in model['chapters'] if r['uid']==plan['chapter_uid']]
    if len(rows)!=1:raise ValueError('translation_result/catalog')
    proof=dict(original_text_sha256=original,translation_fields_before={k:rows[0][k] for k in TRANSLATION_FIELDS if k in rows[0]})
    if baseline is not None:proof['baseline']=baseline
    return validate_proof(proof,plan)


def restore_catalog(after,plan,proof):
    proof=validate_proof(proof,plan);before=deepcopy(after)
    rows=[r for r in before['chapters'] if r['uid']==plan['chapter_uid']]
    if len(rows)!=1:raise ValueError('translation_result/catalog')
    for key in TRANSLATION_FIELDS:rows[0].pop(key,None)
    rows[0].update(proof['translation_fields_before'])
    if digest(before)!=plan['catalog_sha256']:raise ValueError('translation_result/catalog_changed')
    catalog_result(before,after,plan['chapter_uid']);return before


class OriginalText(TranslationText):
    def __init__(self):super().__init__();self.text=[]
    def handle_data(self,value):
        if self.stack and self.stack[-1][1] is None and not any(row[0] in ('head','script','style') for row in self.stack):self.text.append(value)


def original_signature(source):
    content_summary(source)  # Apply the same byte/depth limits before parsing.
    parser=OriginalText();parser.feed(source);parser.close()
    text=re.sub(r'\s+',' ',''.join(parser.text)).strip()
    if len(text)<100:raise ValueError('translation_result/empty_original')
    return digest(text)


def catalog_result(before,after,uid):
    left,right=deepcopy(before),deepcopy(after)
    rows=[]
    for model in (left,right):
        choices=[r for r in model['chapters'] if r['uid']==uid]
        if len(choices)!=1:raise ValueError('translation_result/catalog')
        row=choices[0];rows.append(deepcopy(row))
        for key in TRANSLATION_FIELDS:row.pop(key,None)
    if left!=right:raise ValueError('translation_result/catalog_changed')
    version=rows[1].get('translateVersion')
    if version is not None and (type(version) is not int or version<rows[0].get('translateVersion',0)):raise ValueError('translation_result/version')
    return version
