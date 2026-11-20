-- Accept KOReader's literal settings format without permitting executable Lua.
local M={MAX_BYTES=4*1024*1024,MAX_NODES=100000,MAX_DEPTH=128}
local function fail() error('mp_records/invalid_data',0) end
function M.read(raw)
    if type(raw)~='string' or #raw<1 or #raw>M.MAX_BYTES or raw:find('%z') then fail() end
    local at,first,has_return,tokens,previous=1,true,false,0,nil
    while at<=#raw do
        local char=raw:sub(at,at)
        if char:match('%s') then at=at+1
        elseif raw:sub(at,at+3)=='--[[' then
            local stop=raw:find(']]',at+4,true);if not stop then fail() end;at=stop+2
        elseif raw:sub(at,at+1)=='--' then at=(raw:find('\n',at+2,true) or #raw)+1
        else
            tokens=tokens+1;if tokens>M.MAX_NODES*4 then fail() end
            if char=='"' or char=="'" then
                local quote=char;at=at+1;local closed=false
                while at<=#raw do
                    char=raw:sub(at,at)
                    if char=='\\' then at=at+2
                    elseif char==quote then at=at+1;closed=true;break
                    else at=at+1 end
                end
                if not closed then fail() end
                previous='value'
            elseif char:match('[%a_]') then
                local start,stop=raw:find('[%a_][%w_]*',at)
                if start~=at then fail() end
                local word=raw:sub(at,stop)
                if word=='return' and first then has_return=true
                elseif word~='true' and word~='false' and word~='nil' then fail() end
                at=stop+1;previous=word
            elseif char:match('[%d%-]') then
                if char=='-' and previous~='=' and previous~='{' and previous~='['
                    and previous~=',' and previous~=';' and previous~='return' then fail() end
                local start,stop=raw:find('%-?%d+%.?%d*[eE][%+%-]?%d+',at)
                if start~=at then start,stop=raw:find('%-?%d+%.?%d*',at) end
                if start~=at then fail() end;at=stop+1;previous='value'
            elseif char:match('[{}%[%]=,;]') then at=at+1;previous=char
            else fail() end
            first=false
        end
    end
    local chunk=loadstring(has_return and raw or 'return '..raw)
    if not chunk then fail() end;setfenv(chunk,{})
    local ok,data=pcall(chunk);if not ok or type(data)~='table' then fail() end
    local seen,nodes={},0
    local function check(value,depth)
        nodes=nodes+1;if nodes>M.MAX_NODES or depth>M.MAX_DEPTH then fail() end
        local kind=type(value)
        if kind=='table' then
            if seen[value] then fail() end;seen[value]=true
            for key,item in pairs(value) do
                if type(key)~='string' and type(key)~='number' and type(key)~='boolean' then fail() end
                check(key,depth+1);check(item,depth+1)
            end
        elseif kind=='number' then
            if value~=value or value==math.huge or value==-math.huge then fail() end
        elseif kind~='string' and kind~='boolean' then fail() end
    end
    check(data,0);return data
end
function M.record(raw)
    local data=M.read(raw)
    if data.last_xpointer~=nil and (type(data.last_xpointer)~='string' or #data.last_xpointer>65536
        or data.last_xpointer:find('[%z%c]')) then fail() end
    if data.annotations~=nil then
        if type(data.annotations)~='table' or #data.annotations>M.MAX_NODES then fail() end
        local count=0
        for index,row in pairs(data.annotations) do
            count=count+1
            if type(index)~='number' or index%1~=0 or index<1 or index>#data.annotations or type(row)~='table' then fail() end
            if row.drawer~=nil and row.drawer~=false and (type(row.drawer)~='string' or #row.drawer>64) then fail() end
            for _i,key in ipairs({'pos0','pos1','text','note'}) do if row[key]~=nil and type(row[key])~='string' then fail() end end
            if row.drawer and (type(row.pos0)~='string' or type(row.pos1)~='string') then fail() end
            if row.page~=nil and type(row.page)~='string' and type(row.page)~='number' then fail() end
        end
        if count~=#data.annotations then fail() end
    end
    return data
end
function M.summary(raw)
    local ok,data=pcall(M.record,raw)
    if not ok then return {valid=false,notes=0,bookmarks=0,has_position=false,preview='',note_preview=''} end
    local result={valid=true,notes=0,bookmarks=0,has_position=type(data.last_xpointer)=='string',preview='',note_preview=''}
    local chosen
    if type(data.annotations)=='table' then
        for index,row in ipairs(data.annotations) do
            if index>M.MAX_NODES then fail() end
            if type(row)=='table' then
                if row.drawer then result.notes=result.notes+1 else result.bookmarks=result.bookmarks+1 end
                if not chosen or row.drawer and not chosen.drawer
                    or row.drawer and type(row.note)=='string' and row.note~='' and (not chosen.note or chosen.note=='') then chosen=row end
            end
        end
    end
    if chosen then
        local Protocol=require('weread.lib.protocol')
        result.preview=type(chosen.text)=='string' and Protocol.utf8_substr(chosen.text:gsub('[%z%c]',' '),48) or ''
        result.note_preview=type(chosen.note)=='string' and Protocol.utf8_substr(chosen.note:gsub('[%z%c]',' '),48) or ''
    end
    return result
end
function M.same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for key,value in pairs(a) do if not M.same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
return M
