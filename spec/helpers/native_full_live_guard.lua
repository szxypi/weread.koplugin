-- Restrict a real-account probe to the selected book's read-only requests.
local M={}
function M.new(book,version,chapters,credentials,protocol,decode,remote_allowed)
    assert(type(book)=='string' and book:match('^%d+$') and type(version)=='number' and version>0)
    local readers={[protocol.reader_url(book)]=true}
    local encoded_chapters,downloads={},{}
    for _,chapter in ipairs(chapters) do
        local uid=tostring(chapter.chapterUid)
        assert(uid:match('^%d+$'))
        readers[protocol.reader_url(book,uid)]=true
        encoded_chapters[protocol.e(uid)]=true
        local fields={{'bookId',book},{'chapters','0,'..uid},{'bookType','epub'},{'bookVersion',version},
            {'pf','wechat_wx-2001-android-100-weread'},{'pfkey','pfKey'},{'zoneId',1},{'quote',''},
            {'release',1},{'stopAutoPayWhenBNE',1},{'preload',2},{'preview',0},{'offline',1}}
        local parts={}
        for _,pair in ipairs(fields) do parts[#parts+1]=pair[1]..'='..protocol.urlencode(tostring(pair[2])) end
        downloads['https://i.weread.qq.com/book/chapterdownload?'..table.concat(parts,'&')]=true
    end
    local function header(headers,key)
        for name,value in pairs(headers or {}) do
            if type(name)=='string' and name:lower()==key then return value end
        end
    end
    local function native(options)
        local headers=options.headers or {}
        return options.skip_cookie==true and options.persist_response_cookies==false and options.sensitive==true
            and header(headers,'vid')==credentials.vid and header(headers,'accesstoken')==credentials.accessToken
            and not header(headers,'cookie')
    end
    local function web(options)
        return not options.skip_cookie and not header(options.headers,'cookie')
            and not header(options.headers,'authorization') and not header(options.headers,'vid')
            and not header(options.headers,'accesstoken')
    end
    local function body(options)
        if type(options.body)~='string' or #options.body>16384 then return nil end
        local ok,value=pcall(decode,options.body)
        return ok and type(value)=='table' and value or nil
    end
    return function(options)
        if type(options)~='table' or type(options.url)~='string' then return false end
        local method=options.method or (options.body and 'POST' or 'GET')
        if method=='GET' and not options.body and readers[options.url] and web(options) then return true end
        if method=='POST' and options.url:match('^https://weread%.qq%.com/web/book/chapter/e_[0-3]$')
            and web(options) then
            local value=body(options)
            if not value or value.b~=protocol.e(book) or not encoded_chapters[value.c] then return false end
            local keys={b=true,c=true,r=true,ct=true,ps=true,pc=true,sc=true,prevChapter=true,st=true,s=true}
            for key in pairs(value) do if not keys[key] then return false end end
            return true
        end
        if method=='GET' and not options.body and native(options)
            and (options.url=='https://i.weread.qq.com/book/info?bookId='..protocol.urlencode(book)
                or downloads[options.url]) then return true end
        if method=='POST' and options.url=='https://i.weread.qq.com/book/chapterInfos' and native(options) then
            local value=body(options)
            if not value then return false end
            local keys={bookIds=true,synckeys=true,updateTimes=true,maxfreeIdx=true}
            for key in pairs(value) do if not keys[key] then return false end end
            for key in pairs(keys) do
                local array=value[key]
                if type(array)~='table' or #array~=1 or array[1]~=(key=='bookIds' and book or 0) then return false end
                for index in pairs(array) do if index~=1 then return false end end
            end
            return true
        end
        if method=='GET' and not options.body and options.skip_cookie==true
            and options.persist_response_cookies==false and options.sensitive==true
            and options.diagnostic_api=='native_chapter_image' and header(options.headers,'accept')=='image/*'
            and not header(options.headers,'cookie') and not header(options.headers,'vid')
            and not header(options.headers,'accesstoken') then
            return remote_allowed(options.url)==options.url
        end
        return false
    end
end
return M
