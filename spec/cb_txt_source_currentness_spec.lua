package.path='./?.lua;'..package.path
local Check=require('weread.lib.source_currentness')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function copy(value)
    if type(value)~='table' then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
local book='CB_Synthetic';local raw='Synthetic raw TXT.\r\nA second line.'
local expected={book_id=book,chapter_uid='11',chapter_idx=0,raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw}
local catalog={{bookId=book,book={bookId=book,bookVersion=3},updated={{chapterUid=11,chapterIdx=0,version=5}}}}
package.preload['weread.lib.content']=function() return {decode_content_shards=function(first,second,third)
    assert(first=='txt-part-0' and second=='txt-part-1' and third=='');return raw
end} end
local function fixture()
    local state={requests={},valid=true}
    local scope={vid='900000',epoch=1}
    local settings={get_auth_scope=function() return scope end,auth_scope_matches=function() return state.valid end,
        get=function(_self,key,default) return key=='cookies' and {wr_vid='900000',wr_skey='synthetic-current-cookie'} or default end}
    local initial={reader={bookInfo={bookId=book},psvts='synthetic-session',currentChapter={chapterUid=11},progress={chapterUid=11}}}
    local client={settings=settings,json_encode=function() return 'encoded-read-body' end,
        json_decode=function(_self,text)
            if text=='{reader}' then return initial end
            if text=='txt-marker' then return {bookId=state.foreign_marker and 'CB_Other' or book,chapterUid=state.foreign_chapter and 12 or 11} end
            if text=='native-progress' then return {book={bookId=book,chapterUid=0,chapterIdx=0,chapterOffset=state.native_offset or 0,
                progress=0,summary='',updateTime=1,readingTime=state.native_time or 0,recordReadingTime=0,ttsTime=0}} end
            error('unexpected JSON')
        end,
        decode_http_json=function(_self,text)
            if text=='account' then return {vid=state.foreign_account and '900099' or '900000'} end
            if text=='initial-progress' then return {book={bookId=book,chapterUid=0,chapterIdx=0,
                chapterOffset=state.web_offset or 0,progress=0,summary='',updateTime=1}} end
            if text=='progress' then return {book={bookId=book,chapterUid=11,chapterIdx=0,
                chapterOffset=state.web_offset or 25,progress=37,updateTime=123}} end
            assert(text=='catalog')
            local result=copy(catalog)
            if state.changed_catalog and #state.requests==7 then result[1].book.bookVersion=4 end
            return result
        end}
    function client:request(options)
        state.requests[#state.requests+1]=options
        local index=#state.requests
        local text=(state.first and {'account','initial-progress','native-progress','catalog',
            'window.__INITIAL_STATE__={reader};(function(){})();','txt-marker','txt-part-0','txt-part-1',
            'catalog','native-progress','initial-progress','account'}
            or state.upload and {'account','progress','catalog','window.__INITIAL_STATE__={reader};(function(){})();',
                'txt-marker','txt-part-0','txt-part-1','catalog','progress','account'}
            or {'account','catalog','window.__INITIAL_STATE__={reader};(function(){})();',
                'txt-marker','txt-part-0','txt-part-1','catalog','account'})[index]
        if state.change_web_at==index then state.web_offset=26 end
        if state.change_native_at==index then state.native_offset=1 end
        options.sink(text);options.sink(nil)
        if state.change_session_at==index then state.valid=false end
        return 1,state.fail_at==index and 401 or 200,{}
    end
    return client,state
end
local client,state=fixture()
local proof=Check.fetch_cb_txt(client,expected)
expect(Check.packet_cb_txt(proof,expected) and proof.basis=='raw_txt_utf16' and #state.requests==8,'TXT proof failed')
expect(not Check.packet_cb(proof,expected) and not Check.packet_txt(proof,expected),'TXT proof escaped its typed consumer')
for _i,options in ipairs(state.requests) do
    expect(options.sensitive and options.skip_cookie and options.persist_response_cookies==false,'TXT access was not frozen')
end
client,state=fixture();local versions=0
proof=Check.fetch_cb_txt_versioned(client,expected,nil,function(value)
    versions=versions+1;assert(value[1].book.bookVersion==3)
end)
expect(Check.packet_cb_txt(proof,expected) and versions==2 and #state.requests==8,'TXT catalog versions were not checked twice')
for _i,stop in ipairs({1,2}) do
    client,state=fixture();versions=0
    expect(not pcall(Check.fetch_cb_txt_versioned,client,expected,nil,function()
        versions=versions+1;if versions==stop then error('synthetic version mismatch') end
    end) and #state.requests==(stop==1 and 2 or 7),'TXT version mismatch did not stop proof')
end
client,state=fixture()
expect(not pcall(Check.fetch_cb_txt_versioned,client,expected,nil,nil) and #state.requests==0,'TXT missing version check accepted')
for index=1,8 do
    client,state=fixture();state.fail_at=index
    local result=Check.run_cb_txt(client,expected)
    expect(result.error=='source_web_expired' and not result.check and #state.requests==index,'TXT 401 retried or misreported')
end
client,state=fixture();state.foreign_marker=true
expect(Check.run_cb_txt(client,expected).error=='source_currentness_unavailable' and #state.requests==4,'foreign TXT marker accepted')
client,state=fixture();state.foreign_chapter=true
expect(Check.run_cb_txt(client,expected).error=='source_currentness_unavailable' and #state.requests==4,'foreign TXT chapter accepted')
client,state=fixture();state.foreign_account=true
expect(Check.run_cb_txt(client,expected).error=='source_currentness_unavailable' and #state.requests==1,'foreign owner accepted')
client,state=fixture();state.change_session_at=4
expect(Check.run_cb_txt(client,expected).error=='source_currentness_unavailable' and #state.requests==4,'changed session continued')
client,state=fixture();state.changed_catalog=true
expect(Check.run_cb_txt(client,expected).error=='source_currentness_unavailable' and #state.requests==8,'changed catalog accepted')
client,state=fixture();local changed=copy(expected);changed.raw_sha256=string.rep('a',64)
expect(Check.run_cb_txt(client,changed).error=='source_currentness_unavailable' and #state.requests==8,'changed TXT bytes accepted')
local other=copy(expected);other.book_id='900001'
client,state=fixture();expect(Check.run_cb_txt(client,other).error=='source_currentness_unavailable' and #state.requests==0,
    'numeric book entered imported TXT path')
local malformed=copy(proof);malformed.basis='filtered_xhtml_utf16'
expect(not Check.packet_cb_txt(malformed,expected),'wrong coordinate basis accepted')
malformed=copy(proof);malformed.extra='source data'
expect(not Check.packet_cb_txt(malformed,expected),'extra source data entered proof')
local initial=assert(require('weread.lib.cb_initial_state').from(
    {book={bookId=book,chapterUid=0,chapterIdx=0,chapterOffset=0,progress=0,summary='',updateTime=1}},book))
local credentials={vid='900000',deviceId='eink334691225'..string.rep('1',19),accessToken='synthetic-access',refreshToken='synthetic-refresh'}
local function first_fixture()
    local c,s=fixture();s.first=true
    local store={read=function() return credentials,1,nil,s.native_pending end}
    return c,s,assert(require('weread.lib.native_read_access').capture(c.settings,store))
end
local selected
client,state,selected=first_fixture()
proof=Check.fetch_cb_txt_initial(client,expected,nil,initial,selected)
expect(Check.packet_cb_txt(proof,expected) and #state.requests==12,'initial TXT proof missed a channel')
for _i,index in ipairs({2,11}) do
    client,state,selected=first_fixture();state.change_web_at=index
    expect(Check.run_cb_txt_initial(client,expected,nil,initial,selected).error=='source_remote_changed'
        and #state.requests==index,'changed Web initial state accepted')
end
for _i,index in ipairs({3,10}) do
    client,state,selected=first_fixture();state.change_native_at=index
    expect(Check.run_cb_txt_initial(client,expected,nil,initial,selected).error=='source_remote_changed'
        and #state.requests==index,'changed native initial state accepted')
end
client,state,selected=first_fixture();state.native_time=1
expect(Check.run_cb_txt_initial(client,expected,nil,initial,selected).error=='source_remote_changed'
    and #state.requests==3,'nonzero native time accepted')
client,state,selected=first_fixture();state.fail_at=3
expect(Check.run_cb_txt_initial(client,expected,nil,initial,selected).error=='source_native_expired'
    and #state.requests==3,'native 401 was not isolated')
local remote={book_id=book,source='web',chapter_uid='11',chapter_idx=0,chapter_offset=25,raw_percent=37,
    updated_at=123,has_chapter_index=true,has_chapter_offset=true}
client,state=fixture();state.upload=true
proof=Check.fetch_cb_txt_upload(client,expected,nil,remote)
expect(Check.packet_cb_txt(proof,expected) and #state.requests==10,'existing TXT proof missed progress reads')
for _i,index in ipairs({2,9}) do
    client,state=fixture();state.upload=true;state.change_web_at=index
    expect(Check.run_cb_txt_upload(client,expected,nil,remote).error=='source_remote_changed'
        and #state.requests==index,'changed Web position accepted')
end
print('cb_txt_source_currentness_spec: '..checks..' checks')
