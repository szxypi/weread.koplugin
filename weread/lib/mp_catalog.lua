-- Existing first-page MP GET, isolated from settings writes and credential renewal.
local Access=require('weread.lib.read_access')
local Cookie=require('weread.lib.cookie')
local Protocol=require('weread.lib.protocol')
local Identity=require('weread.lib.mp_cache_identity')
local M={MAX_BYTES=4*1024*1024,MAX_RESULT=2*1024*1024,MAX_ROWS=100}
local function fail() error('mp_catalog/invalid',0) end
local function array(value,maximum)
    if type(value)~='table' or #value>maximum then fail() end
    local count=0
    for key in pairs(value) do
        count=count+1;if type(key)~='number' or key%1~=0 or key<1 or key>#value then fail() end
    end
    if count~=#value then fail() end
    return value
end
local function identifier(value)
    if value==nil or value=='' then return '' end
    if type(value)=='number' and value>=0 and value<=9007199254740991 and value%1==0 then value=string.format('%.0f',value) end
    if type(value)~='string' or #value>512 or value:find('[%z%c%s]') then fail() end
    return value
end
local function text(value,maximum)
    if value==nil then return '' end
    if type(value)~='string' or #value>maximum or value:find('[%z%c]')
        or Protocol.utf8_substr(value,#value+1)~=value then fail() end
    return value
end
local function first(...)
    for index=1,select('#',...) do local value=select(index,...);if value~=nil and value~='' then return value end end
end
local function headers(settings)
    return text(settings:get('wr_ticket',''),4096),text(settings:get('wr_wrpa',''),4096)
end
function M.capture(settings,book)
    local id=type(book)=='table' and (book.book_id or book.bookId)
    if type(id)~='string' or #id>27 or not id:match('^MP_WXS_[1-9]%d*$')
        or book.bookId~=nil and book.bookId~=id then return nil end
    local access=Access.capture(settings);if not access or not access.web then return nil end
    local ticket,wrpa=headers(settings)
    return {book_id=id,access=access,ticket=ticket,wrpa=wrpa}
end
function M.matches(settings,input)
    local ok,ticket,wrpa=pcall(headers,settings)
    return ok and Access.matches(settings,input.access) and input.ticket==ticket and input.wrpa==wrpa
end
-- Whitelist the pipe/cache record again in the parent; never store raw responses.
function M.rows(rows,book_id)
    local normalized={}
    for _i,row in ipairs(array(rows,M.MAX_ROWS)) do
        if type(row)~='table' then fail() end
        local ids,seen={},{}
        for _j,value in ipairs(array(row.reviewIds==nil and {} or row.reviewIds,8)) do
            value=identifier(value);if value~='' and not seen[value] then ids[#ids+1]=value;seen[value]=true end
        end
        local date=row.createTime==nil and 0 or row.createTime
        if type(date)~='number' or date<0 or date>4102444800 or date%1~=0 then fail() end
        local article={reviewId=identifier(row.reviewId),originalId=identifier(row.originalId),bookId=identifier(row.bookId),
            reviewIds=ids,title=text(row.title,4096),sourceUrl=text(row.sourceUrl,4096),pic_url=text(row.pic_url,4096),createTime=date}
        if not Identity.key({book_id=book_id},article) then fail() end
        normalized[#normalized+1]=article
    end
    return normalized
end
function M.project(data,book_id)
    if type(data)~='table' then fail() end
    local code=data.errCode
    if code==nil then code=data.errcode end
    if code==nil then code=0 end
    if type(code)~='number' or code%1~=0 or code<-2147483648 or code>2147483647
        or data.errCode~=nil and data.errcode~=nil and data.errCode~=data.errcode then fail() end
    if code~=0 then return {ok=false,kind=code==-2041 and 'verification' or code==-2012 and 'login' or 'unavailable'} end
    local rows={}
    for _i,group in ipairs(array(data.reviews,M.MAX_ROWS)) do
        if type(group)~='table' then fail() end
        for _j,sub in ipairs(array(group.subReviews,M.MAX_ROWS)) do
            if type(sub)~='table' or sub.review~=nil and type(sub.review)~='table' then fail() end
            local review=sub.review or sub
            local mp=review.mpInfo==nil and {} or review.mpInfo;if type(mp)~='table' then fail() end
            local outer,inner,original=identifier(sub.reviewId),identifier(review.reviewId),identifier(mp.originalId)
            local ids,seen={},{}
            for _k,value in ipairs({outer,inner,original}) do if value~='' and not seen[value] then ids[#ids+1]=value;seen[value]=true end end
            rows[#rows+1]={reviewId=first(inner,outer) or '',reviewIds=ids,originalId=original,bookId=review.belongBookId,
                title=mp.title,pic_url=mp.pic_url,createTime=review.createTime,
                sourceUrl=first(mp.content_url,mp.contentUrl,mp.source_url,mp.sourceUrl,mp.url,
                    review.content_url,review.contentUrl,review.source_url,review.sourceUrl,review.url)}
            if #rows>M.MAX_ROWS then fail() end
        end
    end
    return {ok=true,articles=M.rows(rows,book_id)}
end
function M.read(client,input)
    local chunks,bytes,overflow={},0,false
    local request_headers={Cookie=Cookie.to_header(input.access.web.cookies),Accept='application/json, text/plain, */*',Referer='https://weread.qq.com/'}
    if input.ticket~='' then request_headers['x-wr-ticket']=input.ticket end
    if input.wrpa~='' then request_headers['x-wrpa-0']=input.wrpa end
    local _,code=client:request{url='https://weread.qq.com/web/mp/articles?bookId='..Protocol.urlencode(input.book_id)..'&maxIdx=0&count=100',
        method='GET',headers=request_headers,skip_cookie=true,persist_response_cookies=false,sensitive=true,
        diagnostic_api='mp_catalog',timeout={10,20},sink=function(chunk)
            if chunk then bytes=bytes+#chunk;if bytes>M.MAX_BYTES then overflow=true;return nil,'response_limit' end;chunks[#chunks+1]=chunk end
            return 1
        end}
    if overflow then fail() end
    if code~=200 then return {ok=false,kind=code==401 and 'login' or 'unavailable'} end
    local data=client:json_decode(table.concat(chunks))
    local array_mt=getmetatable(client:json_decode('[]'))
    local function check_empty(value)
        if array_mt and type(value)=='table' and next(value)==nil and getmetatable(value)~=array_mt then fail() end
    end
    if type(data)=='table' then
        check_empty(data.reviews)
        for _i,group in ipairs(type(data.reviews)=='table' and data.reviews or {}) do
            if type(group)=='table' then check_empty(group.subReviews) end
        end
    end
    return M.project(data,input.book_id)
end
return M
