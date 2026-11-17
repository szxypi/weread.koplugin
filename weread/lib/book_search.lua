-- Bounded, read-only Web Reader search pagination. A returned range is a
-- candidate only; a caller must verify it against the original chapter before
-- navigating. This module neither fetches nor stores book content.
local Protocol = require('weread.lib.protocol')
local Access = require('weread.lib.read_access')
local Cookie = require('weread.lib.cookie')

local M = {}
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_ROWS, MAX_WORDS, MAX_HITS, MAX_PAGES = 200, 200, 10000, 128

local function identity(value)
    if type(value)=='number' then
        if value~=value or value%1~=0 or value<1 or value>MAX_SAFE_INTEGER then return nil end
        value=string.format('%.0f',value)
    end
    if type(value)~='string' or #value>20 or not value:match('^[1-9]%d*$') then return nil end
    return value
end

local function offset(value)
    return type(value)=='number' and value==value and value%1==0 and value>=0 and value<=MAX_SAFE_INTEGER
end

local function dense(values,limit)
    if type(values)~='table' or #values>limit then return false end
    local count=0
    for key in pairs(values) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#values then return false end
        count=count+1
    end
    return count==#values
end

local function later(a,b,order)
    local x,y=order[a.chapter],order[b.chapter]
    return x and y and (x>y or x==y and (a.start>b.start or a.start==b.start and a.finish>b.finish))
end

function M.new(book_id, keyword, chapters, first_uid)
    book_id=identity(book_id)
    if not book_id or type(keyword)~='string' or #keyword<1 or #keyword>160
        or keyword:find('[%z%c]') or keyword:match('^%s*$')
        or Protocol.utf8_substr(keyword,#keyword+1)~=keyword
        or not dense(chapters,10000) or #chapters<1 then return nil,'invalid_search' end
    local order={}
    for index,row in ipairs(chapters) do
        local uid=type(row)=='table' and identity(row.chapterUid or row.chapterId or row.chapter_uid)
        if not uid or order[uid] then return nil,'invalid_catalog' end
        order[uid]=index
    end
    local first=first_uid and identity(first_uid) or identity(chapters[1].chapterUid or chapters[1].chapterId or chapters[1].chapter_uid)
    if not first or not order[first] then return nil,'invalid_catalog' end
    return {book=book_id,keyword=keyword,order=order,cursor={chapter=first,start=0,finish=0},
        seen={},pages=0,hit_count=0,finished=false}
end

function M.url(state)
    if type(state)~='table' or state.finished or state.pages>=MAX_PAGES then return nil end
    return 'https://weread.qq.com/web/book/search_v2?'..Protocol.sorted_query({
        bookId=state.book,chapterUid=state.cursor.chapter,keyword=state.keyword,
        posBegin=state.cursor.start,posEnd=state.cursor.finish,mode='scrollDown',count=50,
    })
end

function M.accept(state, data)
    if type(state)~='table' or state.finished or state.pages>=MAX_PAGES or type(data)~='table'
        or data.errCode~=nil and data.errCode~=0 or data.errcode~=nil and data.errcode~=0
        or data.scrollDownHasMore~=0 and data.scrollDownHasMore~=1 then return nil,'invalid_response' end
    local rows=data.results
    if rows==nil then rows={} end
    if not dense(rows,MAX_ROWS) or data.scrollDownHasMore==1 and #rows==0 then
        return nil,'invalid_response'
    end
    local hits,new_seen,previous,hit_bytes={}, {},nil,0
    for _i,row in ipairs(rows) do
        local uid=type(row)=='table' and identity(row.chapterUid)
        if not uid or not state.order[uid] or not offset(row.posBegin) or not offset(row.posEnd)
            or row.posEnd<=row.posBegin or type(row.text)~='string' or #row.text>16384
            or row.text:find('[%z\1-\8\11-\31\127]') or Protocol.utf8_substr(row.text,#row.text+1)~=row.text
            or not dense(row.matchWords,MAX_WORDS) then return nil,'invalid_response' end
        local position={chapter=uid,start=row.posBegin,finish=row.posEnd}
        if previous and later(previous,position,state.order) then return nil,'invalid_order' end
        previous=position
        for _j,word in ipairs(row.matchWords) do
            if type(word)~='table' or type(word.word)~='string' or #word.word>160
                or word.word:find('[%z%c]') or Protocol.utf8_substr(word.word,#word.word+1)~=word.word
                or not offset(word.posBegin) or not offset(word.posEnd) or word.posEnd<=word.posBegin
                or word.posBegin<row.posBegin or word.posEnd>row.posEnd then return nil,'invalid_response' end
            if word.word==state.keyword then
                local key=uid..':'..string.format('%.0f',word.posBegin)..':'..string.format('%.0f',word.posEnd)
                if not state.seen[key] and not new_seen[key] then
                    hit_bytes=hit_bytes+#row.text+#word.word
                    if #hits>=1000 or hit_bytes>2*1024*1024 then return nil,'limit' end
                    new_seen[key]=true
                    hits[#hits+1]={chapter_uid=uid,start=word.posBegin,finish=word.posEnd,
                        text=word.word,context=row.text,source_verified=false}
                end
            end
        end
    end
    if state.hit_count+#hits>MAX_HITS then return nil,'limit' end
    if previous and not later(previous,state.cursor,state.order) then
        return nil,'invalid_cursor'
    end
    for key in pairs(new_seen) do state.seen[key]=true end
    state.hit_count=state.hit_count+#hits;state.pages=state.pages+1
    if previous then state.cursor=previous end
    state.finished=data.scrollDownHasMore==0
    return {hits=hits,finished=state.finished,limit_reached=not state.finished and state.pages>=MAX_PAGES}
end

-- One page, with a pinned Web session and independent owner check. This is a
-- synchronous worker primitive; callers must run it away from the UI thread.
function M.fetch(client, state, selected)
    if type(client)~='table' or not client.settings then return nil,'access_required' end
    selected=selected or Access.capture(client.settings)
    local cookies=selected and selected.web and selected.web.cookies
    if not cookies or not identity(cookies.wr_vid) then return nil,'access_required' end
    if not Access.matches(client.settings,selected) then return nil,'session_changed' end
    local url=M.url(state)
    if not url then return nil,'search_complete' end
    local function request(target,maximum,account)
        if not Access.matches(client.settings,selected) then return nil,'session_changed' end
        local chunks,size,exceeded={},0,false
        local headers={Cookie=Cookie.to_header(cookies),Origin='https://weread.qq.com',
            Referer=Protocol.reader_url(state.book,state.cursor.chapter)}
        if account then headers['X-Vid'],headers['X-Skey']=cookies.wr_vid,cookies.wr_skey end
        local ok,_,code=pcall(client.request,client,{url=target,method='GET',headers=headers,
            skip_cookie=true,persist_response_cookies=false,sensitive=true,diagnostic_api='book_search',
            timeout={8,15},sink=function(chunk)
                if not chunk then return 1 end
                size=size+#chunk
                if size>maximum then exceeded=true;return nil,'book_search_limit' end
                chunks[#chunks+1]=chunk;return 1
            end})
        if not Access.matches(client.settings,selected) then return nil,'session_changed' end
        if ok and code==401 and not exceeded then return nil,'web_expired' end
        if ok and code==429 and not exceeded then return nil,'rate_limited' end
        if not ok or code~=200 or exceeded then return nil,'unavailable' end
        local decoded,value=pcall(client.json_decode,client,table.concat(chunks))
        if not decoded or type(value)~='table' then return nil,'invalid_response' end
        local api_code=value.errCode or value.errcode
        if api_code~=nil and api_code~=0 then
            if api_code==-2010 or api_code==-2012 or api_code==-2013 then return nil,'web_expired' end
            return nil,'invalid_response'
        end
        return value
    end
    local account,reason=request('https://weread.qq.com/api/userInfo?userVid='..Protocol.urlencode(cookies.wr_vid),65536,true)
    if not account then return nil,reason end
    local owner=identity(account.vid or account.userVid)
    if owner~=cookies.wr_vid or account.vid and account.userVid and identity(account.vid)~=identity(account.userVid) then
        return nil,'owner_mismatch'
    end
    local page;page,reason=request(url,4*1024*1024,false)
    if not page then return nil,reason end
    if not Access.matches(client.settings,selected) then return nil,'session_changed' end
    return M.accept(state,page)
end

return M
