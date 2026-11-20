-- Export only independently validated, already-cached personal notes.
-- This formatter performs no network, persistence or account mutation.
local Marks=require('weread.lib.my_cloud_marks')
local Thoughts=require('weread.lib.my_cloud_thoughts')
local Notes=require('weread.lib.notes_export')
local M={MAX_ITEMS=Marks.MAX_ROWS+Thoughts.MAX_ROWS,MAX_OUTPUT_BYTES=32*1024*1024}
local function fail(reason) error('cloud_notes_export/'..reason,0) end
local function markdown(value)
    value=value:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;')
    return (value:gsub('([\\`*_{}%[%]()#+%.!|~%-])','\\%1'))
end
local function quote(value) return '> '..markdown(value:gsub('\r\n?','\n')):gsub('\n','\n> ')..'\n\n' end
local function stamp(value) return {available=value~=nil,fetched_at=value and value.fetched_at or nil} end
local function saved_at(value,labels)
    if not value then return markdown(labels.missing)..'\n\n' end
    if value.fetched_at<=4102444800 then
        local ok,date=pcall(os.date,'!%Y-%m-%dT%H:%M:%SZ',value.fetched_at)
        if ok and type(date)=='string' then return markdown(labels.saved)..': '..date..'\n\n' end
    end
    return markdown(labels.saved)..': '..markdown(labels.time_unknown)..'\n\n'
end
function M.write(input,format,codec,sink,labels)
    if type(input)~='table' or not Marks.display_id(input.book_id) or not codec or type(sink)~='function'
        or format~='json' and format~='markdown'
        or input.marks~=nil and type(input.marks)~='table'
        or input.thoughts~=nil and type(input.thoughts)~='table' then fail('invalid') end
    local marks=input.marks and Marks.validate(codec,input.marks,input.book_id)
    local thoughts=input.thoughts and Thoughts.validate(codec,input.thoughts,input.book_id)
    if not marks and not thoughts then fail('unavailable') end
    local book=Notes.book(input.book,input.fallback or 'WeRead notes',input.now)
    local count,bytes=0,0
    local function emit(value)
        if type(value)~='string' then fail('encoding') end
        bytes=bytes+#value;if bytes>M.MAX_OUTPUT_BYTES then fail('too_large') end
        if sink(value)~=true then fail('write') end
    end
    local function encode(value)
        local ok,result=pcall(codec.json_encode,codec,value)
        if not ok or type(result)~='string' then fail('encoding') end
        return result
    end
    local titles={}
    for _i,row in ipairs(marks and marks.chapters or {}) do titles[row.chapterUid]=row.title end
    labels=labels or {author='Author',date='Exported at',marks='Cloud marks',thoughts='Thoughts',
        missing='Not saved on this device',saved='Saved at',time_unknown='Time unavailable',chapter='Chapter',quoted='Quoted text',note='Thought',
        highlight='Highlight',bookmark='Bookmark',mark='Cloud mark',private='Private',public='Public',unknown='Visibility unknown'}
    if format=='json' then
        emit('{"schema":1,"source":"WeRead","book":'..encode(book)..',"snapshots":'..
            encode({marks=stamp(marks),thoughts=stamp(thoughts)})..',"marks":[')
    else
        emit('# '..markdown(book.title)..'\n\n')
        if book.author~='' then emit(markdown(labels.author)..': '..markdown(book.author)..'\n\n') end
        emit(markdown(labels.date)..': '..book.exported_at..'\n\n## '..markdown(labels.marks)..'\n\n')
        emit(saved_at(marks,labels))
    end
    local function record(value,index,section)
        count=count+1;if count>M.MAX_ITEMS then fail('too_many') end
        if format=='json' then
            if index>1 then emit(',') end
            emit(encode(value));return
        end
        local name=section=='marks' and labels[value.kind] or labels.note
        emit('### '..index..' · '..markdown(name)..'\n\n')
        if value.chapter and value.chapter~='' then emit(markdown(labels.chapter)..': '..markdown(value.chapter:gsub('[\r\n\t]+',' '))..'\n\n') end
        if value.visibility then emit(markdown(labels[value.visibility])..'\n\n') end
        if value.text and value.text~='' then emit(quote(value.text)) end
        if value.abstract and value.abstract~='' and value.abstract~=value.text then
            emit(markdown(labels.quoted)..':\n\n'..quote(value.abstract))
        end
        if value.content and value.content~='' then emit(quote(value.content)) end
        emit('---\n\n')
    end
    for index,row in ipairs(marks and marks.updated or {}) do
        local item={kind=row.type==1 and 'highlight' or row.type==0 and 'bookmark' or 'mark',
            text=row.markText,abstract=row.abstract,chapter=titles[row.chapterUid],created_at=row.createTime,
            style=row.style,color_style=row.colorStyle}
        record(item,index,'marks')
    end
    if format=='json' then emit('],"thoughts":[') else
        emit('## '..markdown(labels.thoughts)..'\n\n')
        emit(saved_at(thoughts,labels))
    end
    for index,row in ipairs(thoughts and thoughts.reviews or {}) do
        local item={content=row.content,abstract=row.abstract,chapter=row.chapterName or titles[row.chapterUid],created_at=row.createTime,
            visibility=row.isPrivate==1 and 'private' or row.isPrivate==0 and 'public' or 'unknown'}
        record(item,index,'thoughts')
    end
    if count==0 then fail('empty') end
    if format=='json' then emit(']}\n') end
    return {ok=true,count=count,bytes=bytes}
end
return M
