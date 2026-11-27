-- Worker-only reads for a selected cached chapter. A byte match is a bounded
-- observation, never a grant to upload or a promise about future revisions.
local Access=require('weread.lib.read_access')
local Cookie=require('weread.lib.cookie')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local Reader=require('weread.lib.reader_context')
local Candidate=require('weread.lib.source_upload_candidate')
local M={capture=Access.capture,matches=Access.matches}
local fields={'book_id','chapter_uid','chapter_idx','raw_sha256','raw_bytes'}
local function fail(reason) error('source_currentness/'..reason,0) end
local function integer(value,maximum) return type(value)=='number' and value%1==0 and value>=0 and value<=maximum end
local function hash(value) return type(value)=='string' and #value==64 and value:match('^[0-9a-f]+$') end
local function nullable(value)
    local json=package.loaded.json
    if type(json)=='table' and (value==json.null or type(json.util)=='table' and value==json.util.null) then return nil end
    return value
end
local function normalize_expected(value,cb)
    if type(value)~='table' then return nil end
    local count=0;for _key in pairs(value) do count=count+1 end
    local book=cb and Access.display_book_id(value.book_id) or Access.book_id(value.book_id)
    if count~=5 or book~=value.book_id or cb and (type(book)~='string' or book:sub(1,3)~='CB_')
        or Access.book_id(value.chapter_uid)~=value.chapter_uid
        or not integer(value.chapter_idx,1000000) or not hash(value.raw_sha256)
        or not integer(value.raw_bytes,2*1024*1024) or value.raw_bytes<1 then return nil end
    local out={};for _i,key in ipairs(fields) do out[key]=value[key] end;return out
end
function M.expected(value) return normalize_expected(value,false) end
function M.expected_cb(value) return normalize_expected(value,true) end
local function version(value)
    value=nullable(value)
    if value==nil then return '' end
    if integer(value,9007199254740991) then return string.format('%.0f',value) end
    if type(value)=='string' and #value>=1 and #value<=19 and value:match('^%d+$') then
        local clean=value:gsub('^0+','');return clean~='' and clean or '0'
    end
    fail('catalog')
end
local function success(value)
    if type(value)~='table' then return end
    for _i,key in ipairs({'errcode','errCode'}) do
        local code=nullable(value[key])
        if code~=nil and code~=0 and code~='0' then fail('catalog') end
    end
    local succ=nullable(value.succ)
    if succ~=nil and succ~=true and succ~=1 and succ~='1' then fail('catalog') end
end
local function catalog(payload,book,uid,cb)
    if cb and (type(book)~='string' or book:sub(1,3)~='CB_' or Access.display_book_id(book)~=book) then fail('catalog') end
    local function book_id(value) return cb and Access.display_book_id(value) or Access.book_id(value) end
    if type(payload)~='table' then fail('catalog') end
    success(payload)
    local records=payload.data
    if records==nil then records=payload.books end
    if records==nil then records=payload end
    if type(records)~='table' then fail('catalog') end
    if records.bookId or records.book then records={records} end
    if type(records)~='table' or #records>10000 then fail('catalog') end
    local selected,count=nil,0
    for _i,row in ipairs(records) do
        if type(row)=='table' then
            local nested=nullable(row.book)
            local id=row.bookId or type(nested)=='table' and nested.bookId
            if book_id(id)==book then selected,count=row,count+1 end
        end
    end
    if count~=1 then fail('catalog') end
    success(selected)
    local nested=nullable(selected.book)
    if nested~=nil and (type(nested)~='table' or nested.bookId~=nil and book_id(nested.bookId)~=book) then fail('catalog') end
    local rows=nullable(selected.updated)
    if rows==nil then rows=nullable(selected.chapterInfos) end
    if rows==nil then rows=nullable(selected.chapters) end
    local index=Candidate.chapter_index(rows,uid)
    if index==nil then fail('catalog') end
    local target
    for _i,row in ipairs(rows) do if Access.book_id(row.chapterUid or row.chapterId or row.chapter_uid)==uid then target=row end end
    local pieces={book,uid,tostring(index)}
    for _i,node in ipairs({selected,nested or {},target}) do
        for _j,key in ipairs({'bookVersion','version','contentVersion'}) do pieces[#pieces+1]=version(node[key]) end
    end
    return index,Crypto.sha256_hex(table.concat(pieces,'\0'))
end
function M.catalog(payload,book,uid) return catalog(payload,book,uid,false) end
function M.catalog_cb(payload,book,uid) return catalog(payload,book,uid,true) end
local function project(expected_value,before,reader,raw,after,cb)
    local expected
    if cb then expected=M.expected_cb(expected_value) else expected=M.expected(expected_value) end
    if not expected then fail('expected') end
    local first,stamp=catalog(before,expected.book_id,expected.chapter_uid,cb)
    local last,later=catalog(after,expected.book_id,expected.chapter_uid,cb)
    if first~=last or stamp~=later or first~=expected.chapter_idx then fail('catalog_changed') end
    if type(reader)~='table' or reader.book_id~=expected.book_id or type(reader.psvts)~='string'
        or #reader.psvts<1 or #reader.psvts>4096 or reader.psvts:find('[^!-~]') then fail('reader') end
    if type(raw)~='string' or #raw<1 or #raw>2*1024*1024 then fail('source_invalid') end
    if #raw~=expected.raw_bytes or Crypto.sha256_hex(raw)~=expected.raw_sha256 then fail('source_changed') end
    expected.catalog_stamp,expected.source_current,expected.upload_verified=stamp,true,false
    return expected
end
function M.project(expected_value,before,reader,raw,after) return project(expected_value,before,reader,raw,after,false) end
function M.project_cb(expected_value,before,reader,raw,after) return project(expected_value,before,reader,raw,after,true) end
local function packet(value,expected_value,cb)
    local expected
    if cb then expected=M.expected_cb(expected_value) else expected=M.expected(expected_value) end
    if type(value)~='table' or not expected or not hash(value.catalog_stamp)
        or value.source_current~=true or value.upload_verified~=false then return nil end
    local count=0;for _key in pairs(value) do count=count+1 end
    if count~=8 then return nil end
    for _i,key in ipairs(fields) do if value[key]~=expected[key] then return nil end end
    expected.catalog_stamp,expected.source_current,expected.upload_verified=value.catalog_stamp,true,false
    return expected
end
function M.packet(value,expected_value) return packet(value,expected_value,false) end
function M.packet_cb(value,expected_value) return packet(value,expected_value,true) end
function M.txt_marker(client,raw,book,uid,cb)
    if type(raw)~='string' or #raw>65536 then fail('txt_marker') end
    local ok,value=pcall(client.json_decode,client,raw)
    local book_id=cb and Access.display_book_id or Access.book_id
    if not ok or type(value)~='table' or book_id(value.bookId)~=book then fail('txt_marker') end
    local chapter=nullable(value.chapterUid)
    if chapter~=nil and Access.book_id(chapter)~=uid then fail('txt_marker') end
    for _i,key in ipairs({'errcode','errCode'}) do
        local code=nullable(value[key])
        if code~=nil and code~=0 and code~='0' then fail('txt_marker') end
    end
    local succ=value.succ
    if succ~=nil and succ~=true and succ~=1 and succ~='1' then fail('txt_marker') end
    return true
end
function M.packet_txt(value,expected)
    if type(value)~='table' or value.basis~='raw_txt_utf16' then return nil end
    local stripped={};for key,item in pairs(value) do if key~='basis' then stripped[key]=item end end
    local checked=M.packet(stripped,expected)
    if checked then checked.basis='raw_txt_utf16' end
    return checked
end
-- Imported raw TXT has a distinct typed proof; it never satisfies the
-- XHTML or numeric-book packet consumers.
function M.packet_cb_txt(value,expected)
    if type(value)~='table' or value.basis~='raw_txt_utf16' then return nil end
    local stripped={};for key,item in pairs(value) do if key~='basis' then stripped[key]=item end end
    local checked=M.packet_cb(stripped,expected)
    if checked then checked.basis='raw_txt_utf16' end
    return checked
end
local function initial_native_current(settings,selected,owner)
    if not selected or selected.renewal_pending or not selected.scope or selected.scope.vid~=owner then return false end
    local current=require('weread.lib.native_read_access').capture(settings,selected.store)
    if not current or current.renewal_pending or current.fingerprint~=selected.fingerprint
        or current.scope.vid~=selected.scope.vid or current.scope.epoch~=selected.scope.epoch
        or current.revision~=selected.revision then return false end
    for _i,key in ipairs({'vid','deviceId','accessToken','refreshToken'}) do
        if current.credentials[key]~=selected.credentials[key] then return false end
    end
    return true
end
function M.matches_cb_initial_access(settings,selected,native_selected)
    local cookies=selected and selected.web and selected.web.cookies
    return cookies~=nil and M.matches(settings,selected)
        and initial_native_current(settings,native_selected,cookies.wr_vid) or false
end
-- The authenticated account response can rotate the Web access cookie. Use
-- that value only inside this read: never mutate the selected session, and
-- reject ambiguous or foreign identity cookies instead of guessing.
local function account_cookie(headers,cookies)
    if type(headers)~='table' then return end
    local raw
    for key,value in pairs(headers) do
        if type(key)=='string' and key:lower()=='set-cookie' then
            if raw~=nil then fail('account_cookie') end
            raw=value
        end
    end
    if raw==nil then return end
    if type(raw)=='string' then raw={raw} end
    if type(raw)~='table' or #raw>32 then fail('account_cookie') end
    local access,access_count,vid_count=nil,0,0
    for key,line in pairs(raw) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#raw
            or type(line)~='string' or #line>16384 then fail('account_cookie') end
        for name,value in line:gmatch('([%w_]+)=([^;,\r\n]*)') do
            if name=='wr_vid' then
                vid_count=vid_count+1
                if vid_count>1 or value~=cookies.wr_vid then fail('account_cookie') end
            elseif name=='wr_skey' then
                access_count=access_count+1
                if access_count>1 or #value<8 or #value>4096 or value:find('[%z%c%s;"\\]')
                    or value:find('[\128-\255]') then fail('account_cookie') end
                access=value
            end
        end
    end
    if access then cookies.wr_skey=access end
end
local function fetch(client,expected_value,selected,format,options,cb,resolve_index)
    format=format or 'web_xhtml'
    if format~='web_xhtml' and format~='web_txt' then fail('format') end
    local expected
    if resolve_index then
        if cb or type(expected_value)~='table' then fail('expected') end
        local count,copy=0,{}
        for key,value in pairs(expected_value) do
            if key~='book_id' and key~='chapter_uid' and key~='raw_sha256' and key~='raw_bytes' then fail('expected') end
            count=count+1;copy[key]=value
        end
        if count~=4 then fail('expected') end
        copy.chapter_idx=0;expected=M.expected(copy)
        if expected then expected.chapter_idx=nil end
    elseif cb then expected=M.expected_cb(expected_value) else expected=M.expected(expected_value) end
    local txt_guarded=options and options.cb_txt_guarded==true
        and (options.cb_initial~=nil)~=(options.cb_remote~=nil)
    local txt_readonly=options and options.cb_txt_readonly==true
        and options.cb_initial==nil and options.cb_remote==nil
    if not expected or cb and format~='web_xhtml' and not (txt_readonly or txt_guarded) then fail('expected') end
    selected=selected or M.capture(client.settings)
    local captured=selected and selected.web and selected.web.cookies
    if not captured or not Access.book_id(captured.wr_vid) then fail('web_required') end
    local cookies={};for key,value in pairs(captured) do cookies[key]=value end
    local function current() if not M.matches(client.settings,selected) then fail('session_changed') end end
    local referer=Protocol.reader_url(expected.book_id,expected.chapter_uid)
    local function request(url,body,maximum,as_json,account)
        current()
        local chunks,size,exceeded={},0,false
        local headers={Cookie=Cookie.to_header(cookies),Origin='https://weread.qq.com',Referer=referer,['Content-Type']='application/json;charset=UTF-8'}
        if account then headers['X-Vid'],headers['X-Skey']=cookies.wr_vid,cookies.wr_skey end
        local ok,_,code,response_headers=pcall(client.request,client,{url=url,method=body and 'POST' or 'GET',
            body=body and client:json_encode(body),headers=headers,skip_cookie=true,persist_response_cookies=false,
            sensitive=true,diagnostic_api='source_currentness',timeout={8,15},sink=function(chunk)
                if not chunk then return 1 end
                size=size+#chunk;if size>maximum then exceeded=true;return nil,'source_currentness_limit' end
                chunks[#chunks+1]=chunk;return 1
            end})
        current()
        if ok and code==401 and not exceeded then fail('web_expired') end
        if not ok or code~=200 or exceeded then fail('unavailable') end
        local raw=table.concat(chunks)
        if not as_json then return raw end
        local decoded,value=pcall(client.decode_http_json,client,raw,{sensitive=true,api_name='source_currentness',code=code,headers=response_headers})
        if not decoded or type(value)~='table' then fail('response') end
        return value,response_headers
    end
    local function account()
        local data,headers=request('https://weread.qq.com/api/userInfo?userVid='..Protocol.urlencode(cookies.wr_vid),nil,65536,true,true)
        local id=Access.book_id(data.vid or data.userVid)
        if id~=cookies.wr_vid or data.vid and data.userVid and Access.book_id(data.vid)~=Access.book_id(data.userVid) then fail('owner') end
        if not pcall(success,data) then fail('owner') end
        account_cookie(headers,cookies)
    end
    account()
    local cb_remote=options and options.cb_remote
    local cb_initial=options and options.cb_initial
    local native_selected=options and options.native_selected
    if cb_remote and cb_initial then fail('expected') end
    if options and options.verify_progress and (cb_remote or cb_initial or type(options.verify_progress)~='function') then fail('expected') end
    local progress_read=0
    local function progress()
        progress_read=progress_read+1
        local stamp=tostring(os.time()*1000+progress_read)
        local data=request('https://weread.qq.com/web/book/getProgress?bookId='..Protocol.urlencode(expected.book_id)..'&_='..stamp,nil,65536,true)
        local matches
        if options and options.verify_progress then
            matches=options.verify_progress(data)==true
        else
            matches=cb_initial and require('weread.lib.cb_initial_state').matches(data,cb_initial)
                or cb_remote and require('weread.lib.cb_sync_guard').matches(data,cb_remote)
        end
        if not matches then fail('remote_changed') end
    end
    local native_before,native_counts_before
    local function native_progress()
        local State=require('weread.lib.cb_initial_state')
        local P=require('weread.lib.native_position_protocol')
        local Remote=require('weread.lib.remote_progress')
        local function active()
            return M.matches(client.settings,selected) and initial_native_current(client.settings,native_selected,cookies.wr_vid)
        end
        if not active() then fail('session_changed') end
        local auth=require('weread.lib.native_authorization'):new(client,{expected_vid=cookies.wr_vid,is_current=active})
        local ok,data=pcall(auth._request,auth,'position_progress',
            'https://i.weread.qq.com/book/getProgress?bookId='..Protocol.urlencode(expected.book_id),nil,native_selected.credentials)
        auth:cancel()
        if not ok then
            if data=='native_auth/position_progress/http_401' then fail('native_expired') end
            fail('native_unavailable')
        end
        local point=State.from(data,expected.book_id)
        local node=Remote.node(data,expected.book_id)
        local valid,counts=pcall(P.counts,node)
        if not point or not valid or counts.recordReadingTime~=0 or counts.ttsTime~=0 then
            fail('remote_changed')
        end
        if native_before and (not State.equal(native_before,point) or not P.same_counts(native_counts_before,counts)) then
            fail('remote_changed')
        end
        native_before,native_counts_before=point,counts
    end
    if cb_remote or cb_initial or options and options.verify_progress then progress() end
    if cb_initial then native_progress() end
    local url='https://weread.qq.com/web/book/chapterInfos'
    local body={bookIds={expected.book_id}}
    local before=request(url,body,4*1024*1024,true)
    if options and options.verify_catalog then options.verify_catalog(before) end
    local index=catalog(before,expected.book_id,expected.chapter_uid,cb)
    if resolve_index then expected.chapter_idx=index
    elseif index~=expected.chapter_idx then fail('catalog_changed') end
    local html=request(referer,nil,4*1024*1024,false)
    local parsed,reader=pcall(Reader.project,{book_id=expected.book_id},html,function(text) return client:json_decode(text) end)
    if not parsed then fail('reader') end
    local params=Protocol.make_content_params(expected.book_id,expected.chapter_uid,reader.psvts,{sc=1})
    local parts={}
    if format=='web_txt' then
        if Access.book_id(reader.current_chapter and reader.current_chapter.chapterUid)~=expected.chapter_uid then fail('reader') end
        M.txt_marker(client,request('https://weread.qq.com/web/book/chapter/e_0',params,65536,false),expected.book_id,expected.chapter_uid,cb)
        parts[1]=request('https://weread.qq.com/web/book/chapter/t_0',params,4*1024*1024,false)
        parts[2]=request('https://weread.qq.com/web/book/chapter/t_1',params,4*1024*1024,false)
        if parts[1]=='{}' then fail('source_invalid') end
        if parts[2]=='{}' then parts[2]='' end
        parts[3]=''
    else
        for _i,name in ipairs({'e_0','e_1','e_3'}) do
            parts[#parts+1]=request('https://weread.qq.com/web/book/chapter/'..name,params,4*1024*1024,false)
        end
    end
    local decoded,raw=pcall(require('weread.lib.content').decode_content_shards,unpack(parts))
    if not decoded then fail('source_invalid') end
    local after=request(url,body,4*1024*1024,true)
    if options and options.verify_catalog then options.verify_catalog(after) end
    if cb_initial then native_progress() end
    if cb_remote or cb_initial or options and options.verify_progress then progress() end
    account()
    current()
    local result=project(expected,before,reader,raw,after,cb)
    if format=='web_txt' then result.basis='raw_txt_utf16' end
    return result
end
-- CB_ upload proof is isolated from the ordinary source-only check and binds
-- the exact previously verified Web position before and after source reads.
function M.fetch(client,value,selected,format,options) return fetch(client,value,selected,format,options,false) end
-- This is only a source proof: a unique index from the first catalog must
-- survive the independent second catalog and the exact raw-content check.
function M.fetch_resolving_index(client,value,selected,options,format)
    return fetch(client,value,selected,format,options,false,true)
end
function M.fetch_cb(client,value,selected) return fetch(client,value,selected,'web_xhtml',nil,true) end
-- Read-only: this proof alone cannot create a position or authorize an upload.
function M.fetch_cb_txt(client,value,selected)
    return fetch(client,value,selected,'web_txt',{cb_txt_readonly=true},true)
end
function M.run_cb_txt(client,value,selected)
    local ok,result=pcall(M.fetch_cb_txt,client,value,selected)
    if ok then return {check=result} end
    if result=='source_currentness/web_expired' then return {error='source_web_expired'} end
    return {error='source_currentness_unavailable'}
end
-- The caller supplies a mandatory version check applied to both catalogs;
-- this source-only proof is not permission to dispatch a time upload.
function M.fetch_cb_versioned(client,value,selected,verify_catalog)
    if type(verify_catalog)~='function' then fail('expected') end
    return fetch(client,value,selected,'web_xhtml',{verify_catalog=verify_catalog},true)
end
-- Raw TXT retains its own typed proof; callers still need an independent
-- versioned position and accounting guard before sending any request.
function M.fetch_cb_txt_versioned(client,value,selected,verify_catalog)
    if type(verify_catalog)~='function' then fail('expected') end
    return fetch(client,value,selected,'web_txt',{verify_catalog=verify_catalog,cb_txt_readonly=true},true)
end
local function fetch_cb_upload(client,value,selected,remote,format)
    local expected=M.expected_cb(value)
    local guarded=expected and require('weread.lib.cb_sync_guard').expected(remote,expected.book_id)
    if not guarded then fail('expected') end
    return fetch(client,value,selected,format,{cb_remote=guarded,cb_txt_guarded=format=='web_txt'},true)
end
function M.fetch_cb_upload(client,value,selected,remote) return fetch_cb_upload(client,value,selected,remote,'web_xhtml') end
function M.fetch_cb_txt_upload(client,value,selected,remote) return fetch_cb_upload(client,value,selected,remote,'web_txt') end
-- A separate read-only preparation for first position. Both account channels
-- must still show an explicitly unstarted book and stable native counters.
-- Existing reading time must stay unchanged; the other counters remain zero.
-- The resulting source packet alone never grants permission to send.
local function fetch_cb_initial(client,value,selected,initial,native_selected,format)
    local expected=M.expected_cb(value)
    local State=require('weread.lib.cb_initial_state')
    local P=require('weread.lib.native_position_protocol')
    if not expected or not State.none(initial) or initial.book_id~=expected.book_id
        or not native_selected or native_selected.renewal_pending or not P.credentials(native_selected.credentials)
        or not native_selected.scope then fail('expected') end
    selected=selected or M.capture(client.settings)
    if not selected or not selected.web or not selected.web.cookies
        or not initial_native_current(client.settings,native_selected,selected.web.cookies.wr_vid) then fail('expected') end
    return fetch(client,value,selected,format,{cb_initial=initial,native_selected=native_selected,cb_txt_guarded=format=='web_txt'},true)
end
function M.fetch_cb_initial(client,value,selected,initial,native_selected)
    return fetch_cb_initial(client,value,selected,initial,native_selected,'web_xhtml')
end
function M.fetch_cb_txt_initial(client,value,selected,initial,native_selected)
    return fetch_cb_initial(client,value,selected,initial,native_selected,'web_txt')
end
local function run_cb_initial(fetcher,client,value,selected,initial,native_selected)
    local ok,result=pcall(fetcher,client,value,selected,initial,native_selected)
    if ok then return {check=result} end
    if result=='source_currentness/web_expired' then return {error='source_web_expired'} end
    if result=='source_currentness/native_expired' then return {error='source_native_expired'} end
    if result=='source_currentness/remote_changed' then return {error='source_remote_changed'} end
    return {error='source_currentness_unavailable'}
end
function M.run_cb_initial(client,value,selected,initial,native_selected)
    return run_cb_initial(M.fetch_cb_initial,client,value,selected,initial,native_selected)
end
function M.run_cb_txt_initial(client,value,selected,initial,native_selected)
    return run_cb_initial(M.fetch_cb_txt_initial,client,value,selected,initial,native_selected)
end
local function run_cb_upload(fetcher,client,value,selected,remote)
    local ok,result=pcall(fetcher,client,value,selected,remote)
    if ok then return {check=result} end
    if result=='source_currentness/web_expired' then return {error='source_web_expired'} end
    if result=='source_currentness/remote_changed' then return {error='source_remote_changed'} end
    return {error='source_currentness_unavailable'}
end
function M.run_cb_upload(client,value,selected,remote) return run_cb_upload(M.fetch_cb_upload,client,value,selected,remote) end
function M.run_cb_txt_upload(client,value,selected,remote) return run_cb_upload(M.fetch_cb_txt_upload,client,value,selected,remote) end
function M.run_cb(client,value,selected)
    local ok,result=pcall(M.fetch_cb,client,value,selected)
    if ok then return {check=result} end
    return {error=result=='source_currentness/web_expired' and 'source_web_expired' or 'source_currentness_unavailable'}
end
-- Only a confirmed HTTP status may ask the parent to recover credentials.
-- Body errors, redirects, worker failures and other statuses stay generic.
function M.run(client,expected,selected)
    local ok,value=pcall(M.fetch,client,expected,selected)
    if ok then return {check=value} end
    return {error=value=='source_currentness/web_expired' and 'source_web_expired' or 'source_currentness_unavailable'}
end
function M.run_txt(client,expected,selected)
    local ok,value=pcall(M.fetch,client,expected,selected,'web_txt')
    if ok then return {check=value} end
    return {error=value=='source_currentness/web_expired' and 'source_web_expired' or 'source_currentness_unavailable'}
end
return M
