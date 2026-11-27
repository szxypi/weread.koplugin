"""Bind a native TXT private thought to an independently checked selection."""
import secrets

from annotation_experiment_model import note_text
from native_direct_txt_marks import TxtMarkProbe
from selection_trial_model import TXT_PROTOCOL,bind_txt,validate_plan
from selection_trial_probe import Plan,SelectionProbe


class TxtThoughtProbe(SelectionProbe):
    def __init__(self):
        self.chapter=TxtMarkProbe()
        super().__init__(web=self.chapter.web,notes=self.chapter.notes)

    def prepare(self,saved,credentials,existing=None,*,offset=0):
        if self.plan is not None:raise ValueError('selection_trial/consumed')
        if existing is not None:
            validate_plan(existing)
            if existing['protocol']!=TXT_PROTOCOL or existing['owner']!=saved['vid']:
                raise ValueError('selection_trial/owner')
        source=self.chapter.prepare(saved,credentials,offset,book_id=existing['book_id'] if existing else None)
        chapter=self.chapter.plan
        mark=self.chapter.body
        nonce=existing['nonce'] if existing else secrets.token_hex(16)
        context=dict(bookId=mark['bookId'],chapterUid=str(mark['chapterUid']),bookVersion=0,type=1,
            range=mark['range'],abstract=mark['markText'],isPrivate=1)
        if any(row['content'] in (note_text(nonce),note_text(nonce,True)) for row in chapter.baseline['thoughts'].values()):
            raise ValueError('selection_trial/existing_nonce')
        bound=bind_txt(chapter.bound,context,chapter.baseline,chapter.web_position,nonce,source['source_bytes'])
        if existing is not None and bound!=existing:
            raise ValueError('selection_trial/changed')
        self.plan=Plan(bound,context,chapter.baseline,chapter.chapters,chapter.web_position)
        self.payload=dict(self.chapter.payload,selection_preview=dict(body=dict(context,content=note_text(nonce))))
        return source

    def current(self):
        self.chapter.current()
        plan=self.plan
        nonce=plan.bound['nonce']
        if (bind_txt(self.chapter.plan.bound,plan.context,plan.baseline,plan.web_position,nonce,
                    self.chapter.native_source['source_bytes'])!=plan.bound
                or self.payload['selection_preview']['body']!=dict(plan.context,content=note_text(nonce))
                or self.payload['source_raw_sha256']!=plan.bound['source_sha256']):
            raise ValueError('selection_trial/changed')

    def observe(self,credentials,stage):
        return self.chapter.observe(credentials,stage)
