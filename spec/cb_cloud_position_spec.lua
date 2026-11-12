package.path='./?.lua;'..package.path
local M=require('weread.lib.cb_cloud_position')
local F=require('spec.helpers.thought_edit_fixture');local P=require('weread.lib.native_position_protocol')
local n=0;local function expect(v) n=n+1;assert(v,'check '..n) end
local book='CB_SyntheticOnly';local cat={{chapterUid=17,chapterIdx=4}}
local raw={bookId=book,chapterUid=17,chapterIdx=4,chapterOffset=15,progress=12,summary='Synthetic quote'}
local p=M.state(raw,book,cat,'native');expect(p.kind=='located' and p.index_source=='response' and p.summary_present)
expect(not pcall(P.point,p))
local missing=F.clone(raw);missing.chapterIdx=nil;expect(M.state(missing,book,cat,'web').index_source=='catalog')
missing.summary=nil;missing.chapterTitle='Chapter title';expect(not M.state(missing,book,cat,'web').summary_present)
for _i,v in ipairs({'900001','CB_bad-name','CB_'..string.rep('a',65)}) do expect(not pcall(M.state,raw,v,cat,'web')) end
local zero={bookId=book,chapterUid=0,chapterOffset=0,progress=0}
expect(M.state(zero,book,cat,'web').kind=='no_chapter')
zero.summary='nonempty';expect(M.state(zero,book,cat,'web').kind=='unavailable')
local conflict=F.clone(raw);conflict.chapterIdx=0;expect(M.state(conflict,book,cat,'web').reason=='progress_source_incomplete')
conflict=F.clone(raw);conflict.bookId='CB_Foreign';expect(M.state(conflict,book,cat,'web').reason=='progress_book_mismatch')
expect(M.state({errcode=-1},book,cat,'native').reason=='progress_rejected')
print('cb_cloud_position_spec: '..n..' checks')
