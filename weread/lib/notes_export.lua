-- Local KOReader text highlights and attached notes. No network or reader API.
local Protocol=require('weread.lib.protocol')
local M={MAX_ITEMS=100000,MAX_TEXT_BYTES=65536,MAX_OUTPUT_BYTES=32*1024*1024}
local function fail(reason) error('notes_export/'..reason,0) end
local function text(value,limit)
    if value==nil then return '' end
    if type(value)~='string' or #value>limit or value:find('[%z\1-\8\11\12\14-\31\127]')
        or Protocol.utf8_substr(value,#value+1)~=value then fail('invalid_text') end
    return value:gsub('\r\n?','\n')
end
local function metadata(value)
    return text(value,4096):gsub('[\n\t]+',' '):match('^%s*(.-)%s*$')
end
function M.directory(settings)
    local root=settings.data_dir
    if type(root)~='string' or root=='' or root:find('[%z%c]') then return nil end
    return root:gsub('/+$','')..'/exports/notes'
end
function M.is_export_path(settings,path)
    local directory=M.directory(settings)
    return directory and type(path)=='string' and path:sub(1,#directory+1)==directory..'/' or false
end
function M.book(props,fallback,now)
    props=type(props)=='table' and props or {}
    local title=metadata(props.title)
    if title=='' then title=metadata(fallback or 'Untitled') end
    local author=metadata(props.authors or props.author)
    return {title=title,author=author,exported_at=os.date('!%Y-%m-%dT%H:%M:%SZ',now or os.time())}
end
function M.item(row)
    if type(row)~='table' or not row.drawer then return nil end
    local quote,note=text(row.text,M.MAX_TEXT_BYTES),text(row.note,M.MAX_TEXT_BYTES)
    if not quote:find('%S') and not note:find('%S') then return nil end
    local page
    if type(row.pageref)=='string' then page=metadata(row.pageref)
    elseif type(row.pageno)=='number' and row.pageno>=1 and row.pageno<=1e9 and row.pageno%1==0 then page=tostring(row.pageno) end
    local out={type='highlight',text=quote,note=note,chapter=metadata(row.chapter),created_at=text(row.datetime,128)}
    if page and page~='' then out.page=page end
    return out
end
local function markdown(value)
    value=value:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;')
    return (value:gsub('([\\`*_{}%[%]()#+%.!|~%-])','\\%1'))
end
local function quote_lines(value)
    return '> '..markdown(value):gsub('\n','\n> ')..'\n\n'
end
function M.write(input,format,encode,sink,labels)
    if format~='markdown' and format~='json' then fail('invalid_format') end
    if type(input)~='table' or type(input.annotations)~='table' or #input.annotations>M.MAX_ITEMS then fail('too_many') end
    local book=M.book(input.book,input.fallback,input.now)
    labels=labels or {author='Author',note='Note',page='Recorded page',chapter='Chapter',date='Exported at'}
    local bytes,count=0,0
    local function emit(value)
        if type(value)~='string' then fail('encoding_failed') end
        bytes=bytes+#value
        if bytes>M.MAX_OUTPUT_BYTES then fail('too_large') end
        if sink(value)~=true then fail('write_failed') end
    end
    if format=='json' then
        emit('{"schema":1,"source":"KOReader","book":'..encode(book)..',"annotations":[')
    else
        emit('# '..markdown(book.title)..'\n\n')
        if book.author~='' then emit(markdown(labels.author)..': '..markdown(book.author)..'\n\n') end
        emit(markdown(labels.date)..': '..book.exported_at..'\n\n')
    end
    for _,row in ipairs(input.annotations) do
        local item=M.item(row)
        if item then
            count=count+1
            if format=='json' then
                if count>1 then emit(',') end
                emit(encode(item))
            else
                emit('## '..count..'\n\n')
                if item.chapter~='' then emit(markdown(labels.chapter)..': '..markdown(item.chapter)..'\n\n') end
                if item.page then emit(markdown(labels.page)..': '..markdown(item.page)..'\n\n') end
                if item.text~='' then emit(quote_lines(item.text)) end
                if item.note~='' then emit(markdown(labels.note)..':\n\n'..quote_lines(item.note)) end
                emit('---\n\n')
            end
        end
    end
    if count==0 then fail('no_notes') end
    if format=='json' then emit(']}\n') end
    return {ok=true,count=count,bytes=bytes}
end
function M.filename(title)
    local name=metadata(title):gsub('[/\\:*?"<>|]','_'):gsub('^%.+','')
    name=Protocol.utf8_substr(name,32)
    if name=='' then name='notes' end
    return name
end
return M
