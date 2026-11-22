package.path='./?.lua;'..package.path
local MarkFixture=require('spec.helpers.mark_edit_fixture')
local ThoughtFixture=require('spec.helpers.thought_edit_fixture')
local Mark=require('weread.lib.mark_edit_task');local Thought=require('weread.lib.thought_edit_task')
local Direct=require('weread.lib.native_direct_reference');local Auth=require('weread.lib.native_authorization')
local Access=require('weread.lib.native_read_access')
local client=MarkFixture.codec();local settings,store=MarkFixture.access();settings.data_dir='/synthetic';client.settings=settings
local selected=assert(Access.capture(settings,store));local reference=MarkFixture.reference()
local source='/synthetic/native-reader-v1/chapter.epub';local checks=0;local verify_calls=0;local reason;local source_version=77
local function expect(v,label) checks=checks+1;assert(v,label) end
Mark.observe=function() return MarkFixture.snapshot(client) end
Thought.observe=function() return ThoughtFixture.snapshot(client) end
Direct.verify=function(got_client,got_settings,got_selected,row,file,current)
    expect(got_client==client and got_settings==settings and got_selected==selected and row==reference and file==source and current(),
        'direct selection proof lost its account or source')
    verify_calls=verify_calls+1;if reason then return nil,reason end;return row,nil,source_version
end
Auth.new=function() return {read_book_metadata=function(_,_,id) return {bookId=id,version=77} end,cancel=function() end} end
settings.get_book=function() error('direct proof used unrelated cached book') end
local mark={book_id='900001',operation='create',reference=reference,source_file=source}
local thought={book_id='900001',operation='create',reference=reference,source_file=source,content='Synthetic private thought'}
local first=Mark.preview(client,settings,selected,mark)
expect(first.body.bookId=='900001' and first.body.range==reference.range and first.body.markText==reference.markText,
    'verified direct highlight changed its quote')
local second=Thought.preview(client,settings,selected,thought)
expect(second.body.bookId=='900001' and second.body.range==reference.range and second.body.isPrivate==1,
    'verified direct thought changed its quote or privacy')
source_version=78
expect(not pcall(Mark.preview,client,settings,selected,mark) and not pcall(Thought.preview,client,settings,selected,thought),
    'changed native book version produced a plan');source_version=77
reason='source_changed'
expect(not pcall(Mark.preview,client,settings,selected,mark) and not pcall(Thought.preview,client,settings,selected,thought),
    'changed direct source produced a plan')
reason='auth_expired';local ok,value=pcall(Mark.preview,client,settings,selected,mark)
expect(not ok and Mark.expired(value),'native expiry was not classified')
ok,value=pcall(Thought.preview,client,settings,selected,thought)
expect(not ok and Thought.expired(value),'native thought expiry was not classified')
reason='web_expired';ok,value=pcall(Mark.preview,client,settings,selected,mark)
expect(not ok and Mark.source_login(value),'Web expiry was not classified')
ok,value=pcall(Thought.preview,client,settings,selected,thought)
expect(not ok and Thought.source_login(value) and verify_calls==10,'Web thought expiry or repeated source proof was lost')
print('PASS: native chapter highlight and thought plans independently recheck source ('..checks..' checks)')
