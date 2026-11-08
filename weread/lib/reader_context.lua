-- Download Reader context: strict owner identity, canonical request and fresh
-- session fields. Python and actual Reader responses verified before porting.
local Protocol=require('weread.lib.protocol')
local M={MAX_HTML_BYTES=4*1024*1024}
local function fail(reason) error('reader_context/'..reason,0) end
function M.identifier(value,chapter)
    local kind=type(value)
    if kind~='string' and kind~='number' then fail('invalid_identity') end
    if kind=='number' and (value<(chapter and 0 or 1) or value>9007199254740991 or value%1~=0) then fail('invalid_identity') end
    value=tostring(value)
    if #value>128 or not value:match('^[A-Za-z0-9][A-Za-z0-9_-]*$')
        or not chapter and value:sub(1,7)=='MP_WXS_' then fail('invalid_identity') end
    if value:match('^%d+$') and (#value>20 or value:sub(1,1)=='0' and not (chapter and value=='0')) then fail('invalid_identity') end
    return value
end
function M.book_id(book)
    if type(book)~='table' then fail('invalid_identity') end
    local a=book.book_id~=nil and M.identifier(book.book_id)
    local b=book.bookId~=nil and M.identifier(book.bookId)
    if not (a or b) or a and b and a~=b then fail('invalid_identity') end
    return a or b
end
function M.url(book,chapter)
    local id=M.book_id(book)
    if chapter~=nil then return Protocol.reader_url(id,M.identifier(chapter,true)) end
    local root=Protocol.reader_url(id)
    local value=book.reader_url
    if type(value)~='string' or #value>4096 or value:find('[%z%c%s]') then return root end
    local scheme,host,path=value:match('^([%a][%w+.-]*)://([^/?#]+)([^?#]*)')
    if not scheme or scheme:lower()~='https' or host:lower()~='weread.qq.com' then return root end
    local base=root:sub(#'https://weread.qq.com'+1)
    if path==base then return root end
    if path:sub(1,#base+1)==base..'k' then
        local suffix=path:sub(#base+2)
        if #suffix>=20 and #suffix<=512 and suffix:match('^[0-9a-fg]+$') then return 'https://weread.qq.com'..path end
    end
    return root
end
local function session(value,required,counter)
    if value==nil then if required then fail('invalid_session') end;return end
    if counter and type(value)=='number' and value>=0 and value<=9007199254740991 and value%1==0 then return value end
    if type(value)~='string' or #value>4096 or value:find('[%z%c%s]') or required and value=='' then fail('invalid_session') end
    return value
end
function M.project(book,html,decode)
    local id=M.book_id(book)
    if type(html)~='string' or #html>M.MAX_HTML_BYTES then fail('invalid_response') end
    local encoded=html:match([[window%.__INITIAL_STATE__%s*=%s*(%{.-%})%s*;%s*%(function]])
    local ok,initial=pcall(decode,encoded or '')
    local reader=ok and type(initial)=='table' and initial.reader
    local info=type(reader)=='table' and reader.bookInfo
    if type(info)~='table' then fail('invalid_response') end
    if M.identifier(info.bookId)~=id then fail('book_mismatch') end
    local chapter=reader.currentChapter
    local progress=reader.progress
    if chapter==nil then chapter={} end
    if progress==nil then progress={} end
    if type(chapter)~='table' or type(progress)~='table' then fail('invalid_response') end
    if progress.book~=nil then progress=progress.book end
    if type(progress)~='table' then fail('invalid_response') end
    for _,row in ipairs({chapter,progress}) do
        if row.bookId~=nil and M.identifier(row.bookId)~=id then fail('book_mismatch') end
    end
    local out={book_id=id,psvts=session(reader.psvts,true),pclts=session(reader.pclts,false,true),
        token=session(reader.token),current_chapter=chapter,progress=progress}
    if type(info.title)=='string' then out.title=info.title end
    if type(info.author)=='string' then out.author=info.author end
    return out
end
return M
