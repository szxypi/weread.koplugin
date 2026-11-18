package.path='./?.lua;'..package.path
local Check=require('weread.lib.source_currentness')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function copy(value)
    if type(value)~='table' then return value end
    local out={} for key,item in pairs(value) do out[key]=copy(item) end return out
end
local raw='<html><body><p>Synthetic imported chapter source.</p></body></html>'
local id='CB_Synthetic';local expected={book_id=id,chapter_uid='11',chapter_idx=0,raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw}
local catalog={{bookId=id,book={bookId=id,bookVersion=3},updated={{chapterUid=11,chapterIdx=0,version=5}}}}
local reader={book_id=id,psvts='synthetic-session'}
local proof=Check.project_cb(expected,catalog,reader,raw,catalog)
expect(proof.source_current and proof.upload_verified==false and Check.packet_cb(proof,expected),'CB source did not produce a bounded proof')
expect(not Check.expected(expected) and not Check.packet(proof,expected),'CB proof escaped through numeric consumer')
local numeric=copy(expected);numeric.book_id='900001'
expect(not Check.expected_cb(numeric) and not pcall(Check.project_cb,numeric,catalog,reader,raw,catalog),
    'numeric book entered CB-only source proof')
for _i,change in ipairs({{book_id='CB_bad/'},{book_id='CB_'},{chapter_uid='CB_Chapter'},{raw_bytes=0},
    {raw_sha256=string.rep('z',64)},{chapter_idx=0.5}}) do
    local bad=copy(expected);for key,value in pairs(change) do bad[key]=value end
    expect(not Check.expected_cb(bad),'invalid CB descriptor accepted')
end
local changed=copy(catalog);changed[1].book.bookId='CB_Other'
expect(not pcall(Check.project_cb,expected,changed,reader,raw,changed),'foreign nested book accepted')
changed=copy(catalog);changed[1].updated[2]=copy(changed[1].updated[1])
expect(not pcall(Check.project_cb,expected,changed,reader,raw,changed),'duplicate chapter accepted')
changed=copy(catalog);changed[1].updated[1].version=6
expect(not pcall(Check.project_cb,expected,catalog,reader,raw,changed),'changed catalog accepted')
expect(not pcall(Check.project_cb,expected,catalog,reader,raw..'x',catalog),'changed source accepted')
local extra=copy(proof);extra.raw='private'
expect(not Check.packet_cb(extra,expected),'source content entered proof')
package.preload['weread.lib.content']=function() return {decode_content_shards=function(a,b,c)
    assert(a=='part0' and b=='part1' and c=='part3');return raw
end} end
local function fixture()
    local state={valid=true,requests={},code=200,foreign=false}
    local scope={vid='900000',epoch=1}
    local settings={get_auth_scope=function() return scope end,auth_scope_matches=function() return state.valid end,
        get=function(_self,key,default) return key=='cookies' and {wr_vid='900000',wr_skey='synthetic-current-cookie'} or default end}
    local initial={reader={bookInfo={bookId=id},psvts=reader.psvts,currentChapter={chapterUid=11},progress={chapterUid=11}}}
    local client={settings=settings,json_encode=function() return 'encoded-read-body' end,
        json_decode=function(_self,value)
            if value=='native-progress' then
                return {book={bookId=id,chapterUid=0,chapterIdx=0,chapterOffset=state.native_offset or 0,progress=0,
                    summary='',updateTime=1,readingTime=state.native_time or 0,recordReadingTime=0,ttsTime=0}}
            end
            assert(value=='{reader}');return initial
        end,
        decode_http_json=function(_self,value)
            if value=='account' then return {vid=state.foreign and '900099' or '900000'} end
            if value=='initial-progress' then return {book={bookId=id,chapterUid=0,chapterIdx=0,chapterOffset=state.offset or 0,
                progress=0,summary='',updateTime=1}} end
            if value=='progress' then return {book={bookId=id,chapterUid=11,chapterIdx=0,chapterOffset=state.offset or 25,progress=37,updateTime=123}} end
            assert(value=='catalog');return catalog
        end}
    function client:request(options)
        state.requests[#state.requests+1]=options;local count=#state.requests
        local text=(state.first and {'account','initial-progress','native-progress','catalog','window.__INITIAL_STATE__={reader};(function(){})();',
            'part0','part1','part3','catalog','native-progress','initial-progress','account'}
            or state.upload and {'account','progress','catalog','window.__INITIAL_STATE__={reader};(function(){})();',
            'part0','part1','part3','catalog','progress','account'} or {'account','catalog',
            'window.__INITIAL_STATE__={reader};(function(){})();','part0','part1','part3','catalog','account'})[count]
        if state.change_progress_at==count then state.offset=26 end
        if state.change_native_at==count then state.native_offset=1 end
        options.sink(text);options.sink(nil)
        if state.changed_at==count then state.valid=false end
        return 1,state.fail_at==count and 401 or state.code,{}
    end
    return client,state
end
local client,state=fixture();local result=Check.fetch_cb(client,expected)
expect(Check.packet_cb(result,expected) and #state.requests==8,'CB proof did not use the bounded eight reads')
client,state=fixture();local versions=0
result=Check.fetch_cb_versioned(client,expected,nil,function(value)
    versions=versions+1;assert(value[1].book.bookVersion==3)
end)
expect(Check.packet_cb(result,expected) and versions==2 and #state.requests==8,'both catalogs were not version checked')
for _i,stop in ipairs({1,2}) do
    client,state=fixture();versions=0
    expect(not pcall(Check.fetch_cb_versioned,client,expected,nil,function()
        versions=versions+1;if versions==stop then error('synthetic version mismatch') end
    end) and #state.requests==(stop==1 and 2 or 7),'version mismatch did not stop proof')
end
client,state=fixture()
expect(not pcall(Check.fetch_cb_versioned,client,expected,nil,nil) and #state.requests==0,'missing version check accepted')
client,state=fixture();Check.fetch_cb(client,expected)
for index,options in ipairs(state.requests) do
    expect(options.sensitive and options.skip_cookie and options.persist_response_cookies==false
        and options.headers.Cookie:find('synthetic-current-cookie',1,true),'CB read lost frozen access')
    expect(options.method==(({[1]=true,[3]=true,[8]=true})[index] and 'GET' or 'POST'),'CB read used unexpected method')
end
for index=1,8 do
    client,state=fixture();state.fail_at=index
    local value=Check.run_cb(client,expected)
    expect(value.error=='source_web_expired' and not value.check and #state.requests==index,'CB expiry was retried or misreported')
end
client,state=fixture();state.changed_at=3
expect(Check.run_cb(client,expected).error=='source_currentness_unavailable' and #state.requests==3,'changed CB access continued')
client,state=fixture();state.foreign=true
expect(Check.run_cb(client,expected).error=='source_currentness_unavailable' and #state.requests==1,'foreign account read source')
client,state=fixture()
expect(Check.run(client,expected).error=='source_currentness_unavailable' and #state.requests==0,'numeric path accepted CB source')
expect(not pcall(Check.fetch_cb,client,numeric) and #state.requests==0,'CB-only path accepted numeric source')
local remote={book_id=id,source='web',chapter_uid='11',chapter_idx=0,chapter_offset=25,raw_percent=37,
    updated_at=123,has_chapter_index=true,has_chapter_offset=true}
client,state=fixture();state.upload=true
result=Check.fetch_cb_upload(client,expected,nil,remote)
expect(Check.packet_cb(result,expected) and #state.requests==10,'CB upload proof did not check progress twice')
for _i,index in ipairs({2,9}) do
    client,state=fixture();state.upload=true;state.change_progress_at=index
    local result_=Check.run_cb_upload(client,expected,nil,remote)
    expect(result_.error=='source_remote_changed' and #state.requests==index,'changed remote was not stopped')
end
for index=1,10 do
    client,state=fixture();state.upload=true;state.fail_at=index
    local result_=Check.run_cb_upload(client,expected,nil,remote)
    expect(result_.error=='source_web_expired' and #state.requests==index,'CB upload expiry retried or misreported')
end
client,state=fixture();state.upload=true
local foreign=copy(remote);foreign.book_id='CB_Other'
expect(Check.run_cb_upload(client,expected,nil,foreign).error=='source_currentness_unavailable'
    and #state.requests==0,'foreign selected remote triggered reads')
local initial=assert(require('weread.lib.cb_initial_state').from(
    {book={bookId=id,chapterUid=0,chapterIdx=0,chapterOffset=0,progress=0,summary='',updateTime=1}},id))
local credentials={vid='900000',deviceId='eink334691225'..string.rep('1',19),accessToken='synthetic-access',refreshToken='synthetic-refresh'}
local function first_fixture()
    local c,s=fixture();s.first=true
    local store={read=function() return credentials,1,nil,s.native_pending end}
    local selected=assert(require('weread.lib.native_read_access').capture(c.settings,store))
    return c,s,selected
end
local selected
client,state,selected=first_fixture()
result=Check.fetch_cb_initial(client,expected,nil,initial,selected)
expect(Check.packet_cb(result,expected) and #state.requests==12,'first source proof did not check both channels twice')
for _i,index in ipairs({2,11}) do
    client,state,selected=first_fixture();state.change_progress_at=index
    result=Check.run_cb_initial(client,expected,nil,initial,selected)
    expect(result.error=='source_remote_changed' and #state.requests==index,'changed Web initial state was not stopped')
end
for _i,index in ipairs({3,10}) do
    client,state,selected=first_fixture();state.change_native_at=index
    result=Check.run_cb_initial(client,expected,nil,initial,selected)
    expect(result.error=='source_remote_changed' and #state.requests==index,'changed native initial state was not stopped')
end
client,state,selected=first_fixture();state.native_time=1
expect(Check.run_cb_initial(client,expected,nil,initial,selected).error=='source_remote_changed' and #state.requests==3,
    'existing native time permitted first-position proof')
client,state,selected=first_fixture();state.native_pending=true
expect(Check.run_cb_initial(client,expected,nil,initial,selected).error=='source_currentness_unavailable' and #state.requests==0,
    'pending native renewal permitted first-position proof')
client,state,selected=first_fixture();selected.credentials=copy(selected.credentials);selected.credentials.accessToken='different-token'
expect(Check.run_cb_initial(client,expected,nil,initial,selected).error=='source_currentness_unavailable' and #state.requests==0,
    'altered native credentials permitted first-position proof')
client,state,selected=first_fixture();state.fail_at=3
expect(Check.run_cb_initial(client,expected,nil,initial,selected).error=='source_native_expired' and #state.requests==3,
    'native 401 was not isolated from Web renewal')
client,state,selected=first_fixture();state.fail_at=2
expect(Check.run_cb_initial(client,expected,nil,initial,selected).error=='source_web_expired' and #state.requests==2,
    'Web 401 was not retained')
client,state,selected=first_fixture();local wrong=copy(initial);wrong.book_id='CB_Other'
expect(Check.run_cb_initial(client,expected,nil,wrong,selected).error=='source_currentness_unavailable' and #state.requests==0,
    'foreign initial state triggered reads')
print('cb_source_currentness_spec: '..checks..' checks')
