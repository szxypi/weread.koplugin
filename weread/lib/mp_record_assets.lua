-- Offline resource relocation for title-based MP HTML. Keep every DOM node and
-- text byte; replace only image source attribute values, never normalize HTML.
local Stage=require('weread.lib.mp_download_stage')
local Versions=require('weread.lib.mp_cache_versions')
local Passive=require('weread.lib.mp_export')
local Output=require('weread.lib.notes_export_file')
local M={}
local function fail() error('mp_records/resources',0) end
local function fs() return require('libs/libkoreader-lfs') end
local function inode(a,b) return a and b and a.mode==b.mode and a.dev==b.dev and a.ino==b.ino end
local function missing(path)
    local value,_,code=fs().symlinkattributes(path)
    if not value and code~=2 then fail() end
    return value
end
local function tag_end(raw,at)
    local quote
    for index=at+1,#raw do
        local char=raw:sub(index,index)
        if quote then if char==quote then quote=nil end
        elseif char=='"' or char=="'" then quote=char
        elseif char=='>' then return index end
    end
    fail()
end
function M.header(raw)
    local lower=raw:lower();local start=lower:find('<head[%s>]')
    if not start then
        local html=lower:find('<html[%s>]')
        if lower:find('</head',1,true) or not html or html>256 or not lower:find('<body[%s>]',html) then fail() end
        local finish=tag_end(raw,html)
        raw=raw:sub(1,finish)..'<head></head>'..raw:sub(finish+1)
        lower=raw:lower();start=finish+1
    end
    local finish=tag_end(raw,start);local closing=lower:find('</head%s*>',finish+1)
    if finish>256 or not closing then fail() end
    return raw,finish,closing
end
-- resolve returns nil to retain an existing URL verbatim, or an ASCII local
-- image path. Whitespace, quotes, comments, and all non-image nodes survive.
function M.rewrite(raw,resolve)
    if type(raw)~='string' or #raw>Stage.MAX_HTML or raw:find('%z') then fail() end
    local at,kept,nodes,out=1,1,0,{}
    local lower=raw:lower()
    while true do
        local start=raw:find('<',at,true);if not start then break end
        nodes=nodes+1;if nodes>100000 then fail() end
        if raw:sub(start,start+3)=='<!--' then
            local stop=raw:find('-->',start+4,true);if not stop then fail() end;at=stop+3
        else
            local stop=tag_end(raw,start)
            local closing,name,offset=raw:sub(start+1,stop-1):match('^%s*(/?)%s*([%a][%w:_-]*)()')
            name=name and name:lower()
            if closing=='' and (name=='script' or name=='style') then
                local finish=lower:find('</'..name..'%s*>',stop+1)
                if not finish then fail() end
                if name=='style' and lower:sub(stop+1,finish-1):find('url%s*%(') then fail() end
                at=tag_end(raw,finish)+1
            else
                if closing=='' and (name=='base' or name=='link') then fail() end
                if closing=='' and name=='img' then
                    local cursor,seen=start+offset,false
                    while cursor<stop do
                        local first,last,key=raw:find('^%s*([%w_:.-]+)',cursor)
                        if not first then
                            if not raw:sub(cursor,stop-1):match('^%s*/?%s*$') then fail() end
                            break
                        end
                        key=key:lower();cursor=last+1
                        local _,equals=raw:find('^%s*=%s*',cursor)
                        if equals then
                            cursor=equals+1;local quote=raw:sub(cursor,cursor)
                            local from,to
                            if quote=='"' or quote=="'" then
                                from=cursor+1;to=raw:find(quote,from,true);if not to or to>=stop then fail() end
                                cursor=to+1;to=to-1
                            else
                                from,to=raw:find('^[^%s>]+',cursor);if not from or to>=stop then fail() end
                                cursor=to+1
                            end
                            if key=='srcset' then fail() end
                            if key=='src' then
                                if seen then fail() end;seen=true
                                local value=raw:sub(from,to)
                                local replacement=resolve(value)
                                if replacement then
                                    if not replacement:match('^[%w%._/-]+$') then fail() end
                                    out[#out+1]=raw:sub(kept,from-1);out[#out+1]=replacement;kept=to+1
                                end
                            end
                        elseif key=='src' or key=='srcset' then fail() end
                    end
                end
                at=stop+1
            end
        end
    end
    out[#out+1]=raw:sub(kept);return table.concat(out)
end
local function source(input,raw)
    local value=require('util').htmlEntitiesToUtf8(raw)
    if value=='' or value:sub(1,1)=='#' then return end
    if value:match('^https?://') or value:match('^//') or value:match('^data:image/') then return end
    if value:sub(1,2)=='./' then value=value:sub(3) end
    local prefix=input.asset_name..'/'
    if value:sub(1,#prefix)~=prefix or not value:sub(#prefix+1):match('^img%-%d+%.[%w]+$') then fail() end
    return value
end
local function root(input)
    if not inode(input.root_info,fs().symlinkattributes(input.root)) then fail() end
end
local function parent(input)
    root(input)
    local directory=input.root..'/'..input.asset_name
    local info=missing(directory)
    if info and info.mode~='directory' then fail() end
    return info
end
function M.inspect(input,html)
    root(input);local rows,seen,total={}, {},0
    M.rewrite(html,function(raw)
        local path=source(input,raw);if not path or seen[path] then return end
        if #rows>=Stage.MAX_IMAGES then fail() end
        local directory=parent(input)
        local info=missing(input.root..'/'..path)
        if info and (not directory or info.mode~='file' or info.size<1 or info.size>Stage.MAX_IMAGE) then fail() end
        local ext='png'
        if info then
            local file=io.open(input.root..'/'..path,'rb');if not file then fail() end
            local head=file:read(32) or '';file:close()
            local media;media,ext=Passive.mime(head);if not media then fail() end
            total=total+info.size;if total>Stage.MAX_TOTAL then fail() end
        end
        rows[#rows+1]={path=path,info=info or false,directory=directory or false,ext=ext};seen[path]=true
    end)
    return rows
end
function M.matches(input,rows)
    if type(rows)~='table' or #rows>Stage.MAX_IMAGES then return false end
    local count,total,seen=0,0,{}
    local ok=pcall(function()
        root(input)
        for index,row in pairs(rows) do
            count=count+1
            if type(index)~='number' or index%1~=0 or index<1 or index>#rows or type(row)~='table'
                or source(input,row.path)~=row.path or seen[row.path]
                or not ({png=true,jpg=true,gif=true,webp=true})[row.ext] then fail() end
            seen[row.path]=true
            local directory=parent(input)
            if row.directory then if not inode(row.directory,directory) then fail() end
            elseif directory then fail() end
            local info=missing(input.root..'/'..row.path)
            if row.info then
                if not Versions.same(row.info,info) or info.mode~='file' or info.size<1 or info.size>Stage.MAX_IMAGE then fail() end
                total=total+info.size;if total>Stage.MAX_TOTAL then fail() end
            elseif info then fail() end
        end
        if count~=#rows then fail() end
    end)
    return ok
end
function M.copy(input,stage,html)
    local rows=input.assets
    if not M.matches(input,rows) or not stage:images_owned() then fail() end
    local mapped,seen,images,total={}, {},0,0
    for index,row in ipairs(rows) do
        local name=string.format('img-%04d.%s',index,row.ext)
        mapped[row.path]=stage.generation..'/images/'..name
        if row.info then
            local from=io.open(input.root..'/'..row.path,'rb');if not from then fail() end
            local output
            local ok=pcall(function()
                output=Output.create(stage.directory..'/images','bitmap','html');if not output then fail() end
                local remaining=row.info.size
                while remaining>0 do
                    local chunk=from:read(math.min(65536,remaining))
                    if not chunk or #chunk==0 or not output:write(chunk) then fail() end
                    remaining=remaining-#chunk
                end
                local path=stage.directory..'/images/'..name
                if from:read(1) or not stage:images_owned() or fs().symlinkattributes(path)
                    or not output:sync() or not output:accept(row.info.size) or not os.rename(output.path,path) then fail() end
                images=images+1;total=total+row.info.size
            end)
            from:close();if output then output:abort() end
            if not ok then fail() end
        end
    end
    html=M.rewrite(html,function(raw)
        local path=source(input,raw)
        if path then if not mapped[path] then fail() end;seen[path]=true;return mapped[path] end
    end)
    for path in pairs(mapped) do if not seen[path] then fail() end end
    if not M.matches(input,rows) then fail() end
    return html,images,total
end
return M
