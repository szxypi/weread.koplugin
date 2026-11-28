package.path='./?.lua;./?/init.lua;'..package.path
package.preload['ui/uimanager']=function() return {} end
package.preload['weread.lib.content']=function() return {} end
package.preload['weread.lib.plugin_util']=function()
    return {tr=function(value) return value end,T=function(value) return value end,reader_open_perf=function() return 0 end}
end
local Controller=require('weread.ui.annotation_sync_controller')
local path='/synthetic/book.epub'
local foreign={title='Wrong book',chapters={{chapterUid='1',title='Wrong'}},
    annotation_documents={[path]={clean=true,chapters={{chapterUid='1',title='Wrong'}}}}}
local books={[9007199254740992]=foreign}
local store={documentKey=function(value) return value end,get=function() return nil end,
    importLegacy=function() end,reconcileRanges=function() return {} end}
local detected='9007199254740993'
local host={ui={document={file=path,getToc=function() return {} end}},settings={get=function() return books end},
    external_annotations_db={getDocument=function() return nil end},detectWeReadBook=function() return detected end,
    _annotationStore=function() return store end,_xpointerOverlayPrototypeAvailable=function() return true end}
for key,value in pairs(Controller) do if host[key]==nil then host[key]=value end end
assert(host:_annotationBinding()==nil,'automatic binding accepted a rounded adjacent book key')
host._annotationBinding=function() return {book_id=detected,automatic=true} end
assert(not host:_usesUnifiedAnnotations(),'wrong book descriptor activated annotations')
local context=assert(host:_prepareAnnotationContext(false))
assert(context.book==nil and context.descriptor==nil and #context.catalog==0,
    'wrong book descriptor or catalog attached to the current document')
local exact={title='Correct book',annotation_documents={[path]={clean=true,chapters={}}}}
books[detected]=exact;host._annotation_context=nil
assert(host:_usesUnifiedAnnotations(),'exact string book key did not activate its own annotation descriptor')
context=assert(host:_prepareAnnotationContext(false))
assert(context.book==exact and context.descriptor==exact.annotation_documents[path],
    'exact large string book key was not used')
exact.book_id='9000001';host._annotation_context=nil
assert(not host:_usesUnifiedAnnotations(),'conflicting stored book ID activated its annotation descriptor')
context=assert(host:_prepareAnnotationContext(false))
assert(context.book==nil and context.descriptor==nil,'conflicting stored book ID was attached to the document')
exact.book_id=nil
host._annotationBinding=Controller._annotationBinding
books={[42]={title='Legacy book'}};detected=42
assert(host:_annotationBinding().book_id=='42','safe legacy numeric book binding was lost')
detected=9007199254740992;books={[detected]=foreign}
assert(host:_annotationBinding()==nil,'unsafe numeric book ID was used as an automatic binding')
local Access=require('weread.lib.read_access')
local compatible={book_id=42,bookId='42'}
assert(Access.cached_book({['42']=compatible},'42')==compatible,'matching legacy numeric identity was rejected')
compatible.bookId='43'
local ignored,reason=Access.cached_book({['42']=compatible},'42')
assert(ignored==nil and reason=='identity_conflict','conflicting ID aliases were not rejected')
ignored,reason=Access.cached_book({['42']='invalid'},'42')
assert(ignored==nil and reason=='identity_conflict','malformed book record was accepted')
assert(Access.cached_book({['CB_Synthetic']={book_id='CB_Synthetic'}},'CB_Synthetic'),
    'matching imported book ID was rejected')

local targeted_reads=0
host.settings={get_book=function(_,id,legacy_numeric)
    assert(id=='42' and legacy_numeric==true)
    targeted_reads=targeted_reads+1
    return Access.cached_key(books,id)
end,get=function() error('annotation setup loaded unrelated books') end}
detected=42;books={[42]={book_id=42,title='Legacy book',annotation_documents={[path]={clean=true,chapters={}}}}}
assert(host:_usesUnifiedAnnotations() and targeted_reads==1,'indexed lookup lost or reloaded a legacy book descriptor')
context=assert(host:_prepareAnnotationContext(false))
assert(context.book==books[42] and context.descriptor==books[42].annotation_documents[path] and targeted_reads==2)
books[42].bookId='43'
assert(not host:_annotationBinding(),'indexed lookup bypassed the stored book identity check')
print('annotation_book_identity_spec: safe book binding and descriptors passed')
