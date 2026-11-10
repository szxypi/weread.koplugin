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
function M.expected(value)
    if type(value)~='table' then return nil end
    local count=0;for _key in pairs(value) do count=count+1 end
    if count~=5 or Access.book_id(value.book_id)~=value.book_id or Access.book_id(value.chapter_uid)~=value.chapter_uid
        or not integer(value.chapter_idx,1000000) or not hash(value.raw_sha256)
        or not integer(value.raw_bytes,2*1024*1024) or value.raw_bytes<1 then return nil end
    local out={};for _i,key in ipairs(fields) do out[key]=value[key] end;return out
end
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
function M.catalog(payload,book,uid)
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
            if Access.book_id(id)==book then selected,count=row,count+1 end
        end
    end
    if count~=1 then fail('catalog') end
    success(selected)
    local nested=nullable(selected.book)
    if nested~=nil and (type(nested)~='table' or nested.bookId~=nil and Access.book_id(nested.bookId)~=book) then fail('catalog') end
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
function M.project(expected,before,reader,raw,after)
    expected=M.expected(expected);if not expected then fail('expected') end
    local first,stamp=M.catalog(before,expected.book_id,expected.chapter_uid)
    local last,later=M.catalog(after,expected.book_id,expected.chapter_uid)
    if first~=last or stamp~=later or first~=expected.chapter_idx then fail('catalog_changed') end
    if type(reader)~='table' or reader.book_id~=expected.book_id or type(reader.psvts)~='string'
        or #reader.psvts<1 or #reader.psvts>4096 or reader.psvts:find('[^!-~]') then fail('reader') end
    if type(raw)~='string' or #raw<1 or #raw>2*1024*1024 then fail('source_invalid') end
    if #raw~=expected.raw_bytes or Crypto.sha256_hex(raw)~=expected.raw_sha256 then fail('source_changed') end
    expected.catalog_stamp,expected.source_current,expected.upload_verified=stamp,true,false
    return expected
end
function M.packet(value,expected)
    expected=M.expected(expected)
    if type(value)~='table' or not expected or not hash(value.catalog_stamp)
        or value.source_current~=true or value.upload_verified~=false then return nil end
    local count=0;for _key in pairs(value) do count=count+1 end
    if count~=8 then return nil end
    for _i,key in ipairs(fields) do if value[key]~=expected[key] then return nil end end
    expected.catalog_stamp,expected.source_current,expected.upload_verified=value.catalog_stamp,true,false
    return expected
end
function M.fetch(client,expected,selected)
    expected=M.expected(expected);if not expected then fail('expected') end
    selected=selected or M.capture(client.settings)
    local cookies=selected and selected.web and selected.web.cookies
    if not cookies or not Access.book_id(cookies.wr_vid) then fail('web_required') end
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
        return value
    end
    local function account()
        local data=request('https://weread.qq.com/api/userInfo?userVid='..Protocol.urlencode(cookies.wr_vid),nil,65536,true,true)
        local id=Access.book_id(data.vid or data.userVid)
        if id~=cookies.wr_vid or data.vid and data.userVid and Access.book_id(data.vid)~=Access.book_id(data.userVid) then fail('owner') end
    end
    account()
    local url='https://weread.qq.com/web/book/chapterInfos'
    local body={bookIds={expected.book_id}}
    local before=request(url,body,4*1024*1024,true)
    local index=M.catalog(before,expected.book_id,expected.chapter_uid)
    if index~=expected.chapter_idx then fail('catalog_changed') end
    local html=request(referer,nil,4*1024*1024,false)
    local parsed,reader=pcall(Reader.project,{book_id=expected.book_id},html,function(text) return client:json_decode(text) end)
    if not parsed then fail('reader') end
    local params=Protocol.make_content_params(expected.book_id,expected.chapter_uid,reader.psvts,{sc=1})
    local parts={}
    for _i,name in ipairs({'e_0','e_1','e_3'}) do
        parts[#parts+1]=request('https://weread.qq.com/web/book/chapter/'..name,params,4*1024*1024,false)
    end
    local decoded,raw=pcall(require('weread.lib.content').decode_content_shards,unpack(parts))
    if not decoded then fail('source_invalid') end
    local after=request(url,body,4*1024*1024,true)
    account()
    current()
    return M.project(expected,before,reader,raw,after)
end
-- Only a confirmed HTTP status may ask the parent to recover credentials.
-- Body errors, redirects, worker failures and other statuses stay generic.
function M.run(client,expected,selected)
    local ok,value=pcall(M.fetch,client,expected,selected)
    if ok then return {check=value} end
    return {error=value=='source_currentness/web_expired' and 'source_web_expired' or 'source_currentness_unavailable'}
end
return M
