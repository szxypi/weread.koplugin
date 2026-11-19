package.path='./?.lua;'..package.path
local F=require('spec.helpers.mark_edit_fixture')
local Task=require('weread.lib.mark_edit_task')
local Auth=require('weread.lib.native_authorization')
local Source=require('weread.lib.source_currentness')
local Reference=require('weread.lib.selection_reference')
local Library=require('weread.lib.library_db')
local Access=require('weread.lib.native_read_access')
local client=F.codec();local settings,store=F.access();client.settings=settings
local selected=assert(Access.capture(settings,store))
local snapshot=F.snapshot(client);snapshot.book_id='CB_Synthetic';snapshot.marks.book_id=snapshot.book_id;snapshot.thoughts.book_id=snapshot.book_id
local reference=F.reference();reference.source.book_id=snapshot.book_id
settings.get_book=function(_self,id) assert(id==snapshot.book_id);return {book_id=id} end
Library.new=function() return {getChapters=function() return {} end} end
Task.observe=function(_client,_settings,_selected,id) assert(id==snapshot.book_id);return snapshot end
local format='web_xhtml'
Reference.verify=function(row,book,file) assert(book.book_id==snapshot.book_id and file=='/synthetic.epub');return row,format end
local reads=0
Source.capture=function() return {web={cookies={wr_vid='900000'}}} end
Source.fetch=function() error('numeric source path used for imported book') end
Source.fetch_cb=function(_client,expected)
    reads=reads+1;assert(expected.book_id==snapshot.book_id)
    if reads==2 then error('source_currentness/source_changed',0) end
    return {source_current=true,upload_verified=false}
end
Source.fetch_cb_txt=Source.fetch_cb
Auth.new=function() return {read_book_metadata=function(_self,_credentials,id) return {bookId=id,version=77} end,
    cancel=function() end} end
local input={book_id=snapshot.book_id,operation='create',reference=reference,source_file='/synthetic.epub'}
local plan=Task.preview(client,settings,selected,input)
assert(plan.body.bookId==snapshot.book_id and plan.body.style==1 and plan.body.colorStyle==0 and reads==1)
assert(require('weread.lib.mark_edit_contract').validate_metadata(plan.metadata))
assert(not pcall(Task.preview,client,settings,selected,input),'changed imported source produced a preview')
assert(reads==2,'imported source verification was skipped')
format='web_txt';reads=0
local txt_reads=0;Source.fetch_cb_txt=function(_client,expected)
    txt_reads=txt_reads+1;assert(expected.book_id==snapshot.book_id)
    if txt_reads==2 then error('source_currentness/source_changed',0) end
    return {source_current=true,upload_verified=false,basis='raw_txt_utf16'}
end
plan=Task.preview(client,settings,selected,input)
assert(plan.body.bookId==snapshot.book_id and txt_reads==1 and reads==0,'TXT source proof was not selected')
assert(not pcall(Task.preview,client,settings,selected,input) and txt_reads==2,'changed TXT source produced a preview')
format='unknown';assert(not pcall(Task.preview,client,settings,selected,input),'unknown source format was accepted')
print('mark_edit_cb_preview_spec: source-bound preview and source-change rejection passed')
