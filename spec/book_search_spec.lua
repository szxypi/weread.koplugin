package.path='./?.lua;./?/init.lua;'..package.path
local Search=require('weread.lib.book_search')
local checks=0
local function expect(value,label)
    checks=checks+1
    if not value then error(label or ('check '..checks)) end
end

local chapters={{chapterUid=11,title='First'},{chapterUid='22',title='Second'},{chapterUid=33,title='Third'}}
local function fresh() return assert(Search.new('12345','测试',chapters)) end
local function row(uid,start,finish,word_start,word_finish,text)
    return {chapterUid=uid,posBegin=start,posEnd=finish,text=text or 'synthetic context',
        matchWords={{posBegin=word_start,posEnd=word_finish,word='测试'}}}
end
local state=fresh()
local url=assert(Search.url(state))
expect(url:find('bookId=12345',1,true) and url:find('chapterUid=11',1,true)
    and url:find('keyword=%%E6%%B5%%8B%%E8%%AF%%95') and url:find('posBegin=0',1,true),
    'initial URL did not bind the book, first chapter and encoded search term')
local page=assert(Search.accept(state,{scrollDownHasMore=1,results={row(11,10,30,15,17),row(22,2,20,4,6)}}))
expect(#page.hits==2 and not page.finished and page.hits[2].chapter_uid=='22'
    and page.hits[1].source_verified==false,'first page did not return unverified cross-chapter candidates')
url=assert(Search.url(state))
expect(url:find('chapterUid=22',1,true) and url:find('posBegin=2',1,true)
    and url:find('posEnd=20',1,true),'cursor did not advance with the chapter')
page=assert(Search.accept(state,{scrollDownHasMore=0,results={row(22,2,20,4,6),row(33,1,10,2,4)}}))
expect(page.finished and #page.hits==1 and page.hits[1].chapter_uid=='33' and not Search.url(state),
    'overlap was duplicated or the last page was not closed')
expect(not Search.accept(state,{scrollDownHasMore=0,results={}}),'a completed search accepted another page')

local function reject(data,reason)
    local current=fresh();local before=Search.url(current)
    local result,err=Search.accept(current,data)
    expect(not result and err==reason and current.pages==0 and current.hit_count==0 and Search.url(current)==before,
        'invalid page mutated search state')
end
reject({scrollDownHasMore=1,results={}},'invalid_response')
reject({scrollDownHasMore=true,results={}},'invalid_response')
reject({scrollDownHasMore=0,results=false},'invalid_response')
reject({scrollDownHasMore=0,results={[1]=row(11,1,5,2,4),[3]=row(11,6,9,7,8)}},'invalid_response')
reject({scrollDownHasMore=0,results={row(99,1,5,2,4)}},'invalid_response')
reject({scrollDownHasMore=0,results={row(11,1,5,2,7)}},'invalid_response')
reject({scrollDownHasMore=0,results={row(22,1,5,2,4),row(11,6,9,7,8)}},'invalid_order')
reject({scrollDownHasMore=0,results={'invalid row'}},'invalid_response')
reject({scrollDownHasMore=0,results={row(11,1,5,2,4,'\255')}},'invalid_response')
local repeated=fresh()
assert(Search.accept(repeated,{scrollDownHasMore=1,results={row(11,1,5,2,4)}}))
local again,reason=Search.accept(repeated,{scrollDownHasMore=0,results={row(11,1,5,2,4)}})
expect(not again and reason=='invalid_cursor' and repeated.pages==1,'repeated cursor falsely ended a search')
local empty=fresh();page=assert(Search.accept(empty,{scrollDownHasMore=0}))
expect(page.finished and #page.hits==0,'empty completed result was not retained')
local imported=assert(Search.new('CB_personal','测试',chapters))
expect(Search.url(imported):find('bookId=CB_personal',1,true)~=nil,'imported book search lost its identity')
local long_chapters={{chapterUid='9007199254740992'},{chapterUid='9007199254740993'}}
local long=assert(Search.new('CB_personal','测试',long_chapters))
local long_page=assert(Search.accept(long,{scrollDownHasMore=0,results={row('9007199254740993',1,5,2,4)}}))
expect(long_page.hits[1].chapter_uid=='9007199254740993','large search result lost its identity')
local imprecise=assert(Search.new('CB_personal','测试',long_chapters))
expect(not Search.accept(imprecise,{scrollDownHasMore=0,results={row(9007199254740992,1,5,2,4)}}),
    'an imprecise numeric chapter identifier was accepted')
expect(not Search.new('CB_bad/path','测试',chapters) and not Search.new('CB_','测试',chapters)
    and not Search.new('MP_WXS_123','测试',chapters) and not Search.new('123',' ',chapters)
    and not Search.new('123','bad\nquery',chapters) and not Search.new('123','\255',chapters),
    'unsupported book ID or invalid search term was accepted')
expect(not Search.new('123','测试',{{chapterUid=11},{chapterUid=11}})
    and not Search.new('123','测试',chapters,'99'),'ambiguous or unknown chapter was accepted')

local settings={cookies={wr_vid='123',wr_skey='synthetic-session'}}
function settings:get(key,default) if key=='cookies' then return self.cookies end;return default end
function settings:get_auth_scope() return {vid='123',epoch=1} end
function settings:auth_scope_matches(scope) return scope.vid=='123' and scope.epoch==1 end
local account={vid='123'}
local response={scrollDownHasMore=0,results={row(11,10,20,12,14)}}
local requests,status,search_status,rotate,rotate_on_search,oversize={},200,nil,false,false,false
local client={settings=settings}
function client:request(options)
    requests[#requests+1]=options
    expect(options.method=='GET' and options.skip_cookie and options.sensitive
        and options.persist_response_cookies==false,'request did not pin the private Web session')
    local is_account=options.url:find('/api/userInfo?',1,true)~=nil
    options.sink(oversize and not is_account and string.rep('x',4*1024*1024+1) or is_account and 'account' or 'search');options.sink(nil)
    if rotate or rotate_on_search and not is_account then settings.cookies.wr_skey='new-synthetic-session' end
    return nil,is_account and status or search_status or status,{}
end
function client:json_decode(value) return value=='account' and account or response end
local fetched=fresh();page=assert(Search.fetch(client,fetched))
expect(page.finished and #page.hits==1 and #requests==2 and requests[1].url:find('/api/userInfo?',1,true)
    and requests[2].url:find('/web/book/search_v2?',1,true),'bounded owner check and search were not performed')
account={vid='456'};requests={};fetched=fresh();local result,err=Search.fetch(client,fetched)
expect(not result and err=='owner_mismatch' and #requests==1 and fetched.pages==0,'wrong account reached the search endpoint')
account={vid='123'};requests={};rotate=true;fetched=fresh();result,err=Search.fetch(client,fetched);rotate=false
expect(not result and err=='session_changed' and #requests==1 and fetched.pages==0,'changed session reached or committed search')
settings.cookies.wr_skey='synthetic-session';requests={};rotate_on_search=true;fetched=fresh()
result,err=Search.fetch(client,fetched);rotate_on_search=false
expect(not result and err=='session_changed' and #requests==2 and fetched.pages==0,'late search response crossed a session change')
settings.cookies.wr_skey='synthetic-session';requests={};oversize=true;fetched=fresh()
result,err=Search.fetch(client,fetched);oversize=false
expect(not result and err=='unavailable' and #requests==2 and fetched.pages==0,'oversize response advanced search')
requests={};search_status=429;fetched=fresh();result,err=Search.fetch(client,fetched);search_status=nil
expect(not result and err=='rate_limited' and #requests==2 and fetched.pages==0,'rate-limited search advanced state')
settings.cookies.wr_skey='synthetic-session';status=401;requests={};fetched=fresh();result,err=Search.fetch(client,fetched)
expect(not result and err=='web_http_401' and #requests==1 and fetched.pages==0,'expired session was treated as a search result')
status=200;search_status=401;requests={};fetched=fresh();result,err=Search.fetch(client,fetched);search_status=nil
expect(not result and err=='web_http_401' and #requests==2 and fetched.pages==0,'search HTTP 401 advanced pagination')
response={errCode=-2012};requests={};fetched=fresh();result,err=Search.fetch(client,fetched)
expect(not result and err=='web_expired' and #requests==2 and fetched.pages==0,'unverified business error was treated as HTTP 401')
print(('book_search_spec: %d checks'):format(checks))
