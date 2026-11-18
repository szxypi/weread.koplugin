-- Bounded public catalogue fields, never reader state or credentials.
local Protocol=require('weread.lib.protocol')
local Data=require('weread.lib.discovery_data')
local M={INTRO_LIMIT=2048,TEXT_LIMIT=512}

local function valid_text(value,limit,multiline)
    return type(value)=='string' and value~='' and #value<=limit
        and not value:find(multiline and '[%z\1-\8\11-\31\127]' or '[%z%c]')
        and Protocol.utf8_substr(value,#value+1)==value
end
local function number(value,limit)
    return type(value)=='number' and value==value and value>=0 and value<=limit
end
function M.project(value)
    if type(value)~='table' then return nil end
    local result={}
    if valid_text(value.intro,65536,true) then
        local intro=value.intro
        if #intro>M.INTRO_LIMIT then
            intro=Protocol.utf8_substr(intro:sub(1,M.INTRO_LIMIT-3),M.INTRO_LIMIT)..'…'
        end
        result.intro=intro
    end
    for _,key in ipairs({'publisher','translator'}) do
        if valid_text(value[key],M.TEXT_LIMIT,false) then result[key]=value[key] end
    end
    if number(value.newRating,1000) and number(value.newRatingCount,1e10) and value.newRatingCount%1==0 then
        result.newRating,result.newRatingCount=value.newRating,value.newRatingCount
    end
    return next(result) and result or nil
end

local function raw_book(row)
    local value=row
    for _i=1,4 do
        if type(value)~='table' then return nil end
        if type(value.bookInfo)=='table' then value=value.bookInfo
        elseif type(value.book)=='table' then value=value.book
        else break end
    end
    return value
end

function M.attach(page,data)
    local fields,seen={},{}
    local function consume(rows)
        if type(rows)~='table' then return end
        for _,row in ipairs(rows) do
            local book=Data.book(row)
            if book and not seen[book.bookId] then
                seen[book.bookId]=true
                fields[book.bookId]=M.project(raw_book(row))
            end
        end
    end
    if type(data.results)=='table' then
        for _,group in ipairs(data.results) do if type(group)=='table' then consume(group.books) end end
    else consume(data.books) end
    for _,book in ipairs(page.books) do book._public_info=fields[book.bookId] end
    return page
end
return M
