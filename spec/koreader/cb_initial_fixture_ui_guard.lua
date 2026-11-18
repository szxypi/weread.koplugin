-- Strict scope for a new, self-authored imported-book first-sync experiment.
local M={}
function M.new(input,protocol,cookie)
    local base='https://weread.qq.com'
    local account=base..'/api/userInfo?userVid='..protocol.urlencode(input.owner)
    local progress=base..'/web/book/getProgress?bookId='..protocol.urlencode(input.book)
    local native='https://i.weread.qq.com/book/getProgress?bookId='..protocol.urlencode(input.book)
    local reader,book_reader=protocol.reader_url(input.book,input.chapter),protocol.reader_url(input.book)
    local catalog,write=base..'/web/book/chapterInfos',base..'/web/book/read'
    local content={}
    for _i,name in ipairs({'e_0','e_1','e_3'}) do content[base..'/web/book/chapter/'..name]=true end
    return function(options,writes,decode)
        if type(options)~='table' or options.sensitive~=true or type(options.headers)~='table' then return nil end
        local url,method=options.url,options.method
        if url==native then
            return method=='GET' and options.body==nil and options.skip_cookie==true
                and options.headers.vid==input.owner and options.headers.accessToken==input.native.accessToken and 'read' or nil
        end
        if options.skip_cookie and options.headers.Cookie~=cookie.to_header(input.cookies) then return nil end
        if method=='GET' and options.body==nil then
            if url==account or url==reader or url==book_reader or url==progress then return 'read' end
            local prefix=progress..'&_='
            if type(url)=='string' and url:sub(1,#prefix)==prefix and url:sub(#prefix+1):match('^%d+$') then return 'read' end
            return nil
        end
        if method~='POST' or type(options.body)~='string' then return nil end
        local ok,body=pcall(decode,options.body);if not ok or type(body)~='table' then return nil end
        if url==catalog then
            local n,m=0,0;for _ in pairs(body) do n=n+1 end
            if type(body.bookIds)~='table' then return nil end
            for _ in pairs(body.bookIds) do m=m+1 end
            return n==1 and m==1 and body.bookIds[1]==input.book and 'read' or nil
        end
        if content[url] then
            return body.b==protocol.e(input.book) and body.c==protocol.e(input.chapter) and body.sc==1 and 'read' or nil
        end
        if url~=write or input.armed~=true or writes~=0 or body.b~=protocol.e(input.book) or body.c~=protocol.e(input.chapter)
            or body.ci~=input.chapter_idx or body.co~=input.offset or body.sm~=input.expected_summary
            or type(body.pr)~='number' or body.pr%1~=0 or body.pr<0 or body.pr>100
            or type(body.ct)~='number' or body.ct>os.time() or os.time()-body.ct>30 then return nil end
        local fields={appId=true,b=true,c=true,ci=true,co=true,sm=true,pr=true,ct=true,ps=true,pc=true,s=true}
        local count=0;for key in pairs(body) do if not fields[key] then return nil end;count=count+1 end
        if count~=11 then return nil end
        local signed={};for key,value in pairs(body) do if key~='s' then signed[key]=value end end
        if body.s~=protocol.sign(protocol.sorted_query(signed)) then return nil end
        return 'write'
    end
end
return M
