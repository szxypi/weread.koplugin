-- Limit the owner UI probe to the six reads made by SourceCloud.fetch.
local M={}
function M.new(input,protocol,cookie,parent)
    local progress='https://weread.qq.com/web/book/getProgress?bookId='..protocol.urlencode(input.book)
    local sequence={{'GET',progress},{'GET',protocol.reader_url(input.book,input.chapter)},
        {'POST','https://weread.qq.com/web/book/chapter/e_0'},{'POST','https://weread.qq.com/web/book/chapter/e_1'},
        {'POST','https://weread.qq.com/web/book/chapter/e_3'},{'GET',progress}}
    if input.source_preview then
        local account='https://weread.qq.com/api/userInfo?userVid='..protocol.urlencode(input.owner)
        local catalog='https://weread.qq.com/web/book/chapterInfos'
        local suffix={{'GET',account},{'POST',catalog},{'GET',protocol.reader_url(input.book,input.chapter)},
            {'POST','https://weread.qq.com/web/book/chapter/e_0'},{'POST','https://weread.qq.com/web/book/chapter/e_1'},
            {'POST','https://weread.qq.com/web/book/chapter/e_3'},{'POST',catalog},{'GET',account}}
        for _i,item in ipairs(suffix) do sequence[#sequence+1]=item end
    end
    return function(options,index,pid,decode,reopening)
        local next_item=sequence[index+1]
        local allowed=not reopening and pid~=parent and next_item and options.method==next_item[1]
            and options.url==next_item[2] and options.sensitive==true and options.skip_cookie==true
            and options.persist_response_cookies==false and type(options.headers)=='table'
            and options.headers.Cookie==cookie.to_header(input.cookies)
        if allowed and options.method=='POST' then
            local ok_body,body=pcall(decode,options.body)
            if options.url=='https://weread.qq.com/web/book/chapterInfos' then
                local count=0;if type(body)=='table' then for _key in pairs(body) do count=count+1 end end
                allowed=ok_body and count==1 and type(body.bookIds)=='table' and #body.bookIds==1 and body.bookIds[1]==input.book
            else
                allowed=ok_body and type(body)=='table' and body.b==protocol.e(input.book) and body.c==protocol.e(input.chapter)
            end
        elseif allowed then allowed=options.body==nil end
        return allowed==true
    end
end
return M
