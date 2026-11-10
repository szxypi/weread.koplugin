package.path='./?.lua;'..package.path
local Check=require('weread.lib.source_currentness')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function copy(value)
    if type(value)~='table' then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
local raw='<html><body><p>Original selected chapter body.</p></body></html>'
local expected={book_id='900001',chapter_uid='11',chapter_idx=0,raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw}
local catalog={{bookId='900001',book={bookVersion=3},updated={{chapterUid=11,chapterIdx=0,wordCount=30,version=5}}}}
local reader={book_id='900001',psvts='synthetic-reader-session',current_chapter={chapterUid=22}}
local good=Check.project(expected,catalog,reader,raw,catalog)
expect(good.source_current and good.upload_verified==false and good.chapter_uid=='11' and good.chapter_idx==0,'cloud progress overrode selected chapter')
expect(Check.packet(good,expected) and not good.raw and not good.psvts,'raw/session fields escaped source proof')
local extra=copy(good);extra.raw='private'
expect(not Check.packet(extra,expected),'extra source text accepted in receipt')
for _i,field in ipairs({'raw_sha256','raw_bytes','chapter_idx'}) do
    local changed=copy(expected);changed[field]=field=='raw_sha256' and string.rep('a',64) or expected[field]+1
    expect(not pcall(Check.project,changed,catalog,reader,raw,catalog),'changed descriptor passed')
end
local changed=copy(catalog);changed[1].book.bookVersion=4
expect(not pcall(Check.project,expected,catalog,reader,raw,changed),'catalog moved during check')
expect(Check.project(expected,changed,reader,raw,changed).source_current,'book version inferred source semantics')
expect(not pcall(Check.project,expected,changed,reader,raw..'changed',changed),'version replaced byte identity')
for _i,mode in ipairs({'duplicate_book','duplicate_uid','foreign','missing_index','conflict','empty','rejected','bad_version','false_updated','false_data'}) do
    local value=copy(catalog)
    if mode=='duplicate_book' then value[2]=copy(value[1]) end
    if mode=='duplicate_uid' then value[1].updated[2]=copy(value[1].updated[1]) end
    if mode=='foreign' then value[1].book.bookId='900002' end
    if mode=='missing_index' then value[1].updated[1].chapterIdx=nil end
    if mode=='conflict' then value[1].updated[1].chapter_idx=1 end
    if mode=='empty' then value[1].chapters=value[1].updated;value[1].updated={} end
    if mode=='rejected' then value={errcode=false,data=value} end
    if mode=='bad_version' then value[1].book.bookVersion=true end
    if mode=='false_updated' then value[1].chapters=value[1].updated;value[1].updated=false end
    if mode=='false_data' then value={data=false,books=value} end
    expect(not pcall(Check.catalog,value,'900001','11'),'invalid catalog accepted: '..mode)
end
package.preload['weread.lib.content']=function() return {decode_content_shards=function(a,b,c)
    assert(a=='part0' and b=='part1' and c=='part3');return raw
end} end
local function fixture()
    local state={valid=true,requests={},code=200,changed_at=nil,foreign=false,oversized=false}
    local scope={vid='900000',epoch=1}
    local settings={get_auth_scope=function() return scope end,auth_scope_matches=function() return state.valid end,
        get=function(_self,key,default) return key=='cookies' and {wr_vid='900000',wr_skey='synthetic-current-cookie'} or default end}
    local initial={reader={bookInfo={bookId='900001'},psvts=reader.psvts,currentChapter={chapterUid=22},progress={chapterUid=22}}}
    local client={settings=settings,json_encode=function() return 'encoded-read-body' end,
        json_decode=function(_self,value) assert(value=='{reader}');return initial end,
        decode_http_json=function(_self,value)
            if value=='account' then return {vid=state.foreign and '900099' or '900000'} end
            assert(value=='catalog');return catalog
        end}
    function client:request(options)
        self.settings:get('cookies');state.requests[#state.requests+1]=options
        local count=#state.requests
        local text=({[1]='account',[2]='catalog',[3]='window.__INITIAL_STATE__={reader};(function(){})();',
            [4]='part0',[5]='part1',[6]='part3',[7]='catalog',[8]='account'})[count]
        if state.oversized then text=string.rep('x',65537) end
        options.sink(text);options.sink(nil)
        if state.changed_at==count then state.valid=false end
        return 1,state.code,{}
    end
    return client,state
end
local client,state=fixture()
local result=Check.fetch(client,expected)
expect(Check.packet(result,expected) and #state.requests==8,'fixed eight reads did not bind selected source')
for index,options in ipairs(state.requests) do
    expect(options.sensitive and options.skip_cookie and options.persist_response_cookies==false
        and not options.headers.Authorization and options.headers.Cookie:find('synthetic-current-cookie',1,true),'read lost frozen access scope')
    expect(options.method==(({[1]=true,[3]=true,[8]=true})[index] and 'GET' or 'POST'),'unexpected write route/method')
end
client,state=fixture();state.code=429
expect(not pcall(Check.fetch,client,expected) and #state.requests==1,'429 retried or fetched body')
client,state=fixture();state.changed_at=3
expect(not pcall(Check.fetch,client,expected) and #state.requests==3,'changed access continued source reads')
client,state=fixture();state.foreign=true
expect(not pcall(Check.fetch,client,expected) and #state.requests==1,'foreign account fetched private source')
client,state=fixture();state.oversized=true
expect(not pcall(Check.fetch,client,expected) and #state.requests==1,'oversized account response continued')
print(('source_currentness_spec: %d checks'):format(checks))
