-- Private snapshots and payloads only use captured anonymous pipes.
require('ffi').log=function() end
require('setupkoenv')
package.path='/source/?.lua;'..package.path
local json=require('json');local raw=assert(io.stdin:read(8*1024*1024+1));assert(#raw<=8*1024*1024)
local input=json.decode(raw);local Task=require('weread.lib.thought_edit_task')
local scope={vid=input.owner,epoch=1};local settings={get_auth_scope=function() return scope end,auth_scope_matches=function() return true end}
local credentials={vid=input.owner,accessToken='fixture-access'}
local selected=require('weread.lib.native_read_access').capture(settings,{read=function() return credentials,1 end})
local rows=json.decode('[]')
for _i,row in ipairs(input.snapshot.reviews) do
    local value=json.decode(json.encode(row));value.bookId=input.snapshot.book_id;value.userVid=input.owner
    rows[#rows+1]={reviewId=value.reviewId,review=value}
end
local calls=0;local codec={settings=settings,json_decode=function(_self,v) return json.decode(v) end,json_encode=function(_self,v) return json.encode(v) end}
function codec:request(options)
    assert(options.method=='GET' and not options.body and options.sensitive and options.skip_cookie
        and options.persist_response_cookies==false and not options.headers.Cookie and options.headers.accessToken=='fixture-access')
    local base='https://i.weread.qq.com';local book=input.snapshot.book_id;local response
    if options.url==base..'/review/list?bookId='..book..'&listType=11&listMode=0&mine=1&synckey=0&count=20' then
        response={reviews=rows,totalCount=#rows,hasMore=0}
    elseif options.url==base..'/book/bookmarklist?bookId='..book..'&synckey=0' then response=input.marks
    elseif options.url==base..'/book/info?bookId='..book then response=input.metadata
    else error('thought_contract/transport_scope',0) end
    calls=calls+1;return json.encode(response),200
end
local plans={}
for _i,op in ipairs({'create','edit','delete'}) do
    plans[#plans+1]=Task.preview(codec,settings,selected,{book_id=input.snapshot.book_id,operation=op,
        reference=op=='create' and input.reference or input.thought,content=input.content})
    -- fetched_at is a local cache timestamp, not part of a write precondition.
    plans[#plans].snapshot.fetched_at=input.snapshot.fetched_at
end
assert(calls==5)
io.write('\nWEREAD_THOUGHT_CONTRACT_RESULT='..json.encode(plans)..'\n')
