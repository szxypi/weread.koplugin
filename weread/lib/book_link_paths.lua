-- Resolve original EPUB link paths against the chapters actually packaged.
-- File ownership is checked before anchors; equal basenames are not identities.
local M = {}
local function utf8(number)
    if not number or number<1 or number>0x10ffff or number>=0xd800 and number<=0xdfff then return nil end
    if number<0x80 then return string.char(number) end
    if number<0x800 then return string.char(0xc0+math.floor(number/64),0x80+number%64) end
    if number<0x10000 then return string.char(0xe0+math.floor(number/4096),0x80+math.floor(number/64)%64,0x80+number%64) end
    return string.char(0xf0+math.floor(number/262144),0x80+math.floor(number/4096)%64,0x80+math.floor(number/64)%64,0x80+number%64)
end
function M.attribute(value)
    local named={amp='&',lt='<',gt='>',quot='"',apos="'",nbsp=' '}
    return (tostring(value or ''):gsub('&([^;]+);',function(entity)
        if named[entity] then return named[entity] end
        local number=entity:match('^#[xX]([%x]+)$')
        number=number and tonumber(number,16) or tonumber(entity:match('^#(%d+)$'))
        return utf8(number) or '&' .. entity .. ';'
    end))
end
local function decode(value)
    if value:gsub('%%[%x][%x]',''):find('%%') then return nil end
    value=value:gsub('%%([%x][%x])',function(hex) return string.char(tonumber(hex,16)) end)
    if value:find('[%z\1-\31\127]') then return nil end
    return value
end
local function external(value)
    return value:match('^[%a][%w+%.%-]*:') or value:sub(1,2)=='//'
end
local function normalize(value)
    local parts={}
    for part in value:gmatch('[^/]+') do
        if part=='..' then
            if #parts==0 then return nil end
            parts[#parts]=nil
        elseif part~='.' and part~='' then parts[#parts+1]=part end
    end
    return table.concat(parts,'/')
end
local function path(value,uri)
    if type(value)~='string' then return nil end
    value=value:gsub('\\','/')
    if uri then value=decode(value:match('^[^#]*')) end
    if not value or external(value) or value:find('[%z\1-\31\127]') then return nil end
    return normalize(value)
end
local function add(set,key,value)
    set[key]=set[key] or {};set[key][value]=true
end
local function only(set)
    local result
    for value in pairs(set or {}) do if result then return nil end;result=value end
    return result
end
local function uid(chapter) return tostring(chapter and (chapter.chapterUid or chapter.uid) or '') end
local function fragment(value)
    return (value:gsub('[^%w%.~_%-]',function(char) return string.format('%%%02X',char:byte()) end))
end

function M.build(scans,chapters,chapter_hrefs)
    local index={entries={},files={},basenames={},outputs={},packaged=false}
    local metadata,duplicates={},{}
    for _i,chapter in ipairs(chapters or {}) do
        local key=uid(chapter)
        if metadata[key] then duplicates[key]=true else metadata[key]=chapter end
    end
    for raw_uid,scan in pairs(scans or {}) do
        local key=tostring(raw_uid)
        local chapter=scan.chapter or metadata[key]
        if not duplicates[key] and uid(chapter)==key then
            local entry={anchors={},forward={},paths={},physical=false,anchors_known=scan.anchors_unknown~=true}
            local seen={}
            local function remember(value,uri)
                local candidate=path(value,uri)
                if candidate and candidate~='' and not seen[candidate] then
                    seen[candidate]=true;entry.paths[#entry.paths+1]=candidate
                end
            end
            for _i,value in ipairs(chapter.files or {}) do remember(value) end
            if #entry.paths==0 then
                for _i,name in ipairs({'href','file','filename','fileName','path','chapterPath'}) do remember(chapter[name],name=='href') end
            end
            entry.physical=#entry.paths>0
            if not entry.physical then
                local number=tonumber(chapter.chapterIdx or chapter.index)
                if number and number>0 and number%1==0 then
                    remember(string.format('chapter%d.xhtml',number))
                    remember(string.format('text/chapter%d.xhtml',number))
                    remember(string.format('Text/chapter%d.xhtml',number))
                end
            end
            for _i,value in ipairs(entry.paths) do
                add(index.files,value,key);add(index.basenames,value:match('[^/]+$'),value)
            end
            for anchor,count in pairs(scan.anchor_counts or scan.anchors or {}) do
                local decoded=M.attribute(anchor)
                entry.anchors[decoded]=(entry.anchors[decoded] or 0)+(type(count)=='number' and count or 1)
            end
            for anchor in pairs(scan.forward_ref_ids or {}) do entry.forward[M.attribute(anchor)]=true end
            local output=chapter_hrefs and chapter_hrefs[key]
            if type(output)=='string' and output:match('^chapter%-%d+%.xhtml$') then
                entry.output=output;add(index.outputs,output,key);index.packaged=true
            end
            index.entries[key]=entry
        end
    end
    for _key,entry in pairs(index.entries) do
        if entry.output and not only(index.outputs[entry.output]) then entry.output=nil end
    end
    return index
end

local function resolve(index,current_uid,raw_href,planning)
    local href=M.attribute(raw_href):match('^%s*(.-)%s*$'):gsub('\\','/')
    if external(href) then return nil,'external' end
    local raw_file,raw_anchor=href:match('^(.-)#(.*)$')
    if not raw_file then raw_file=href end
    local file=decode(raw_file)
    local anchor=raw_anchor and decode(raw_anchor)
    if not file or raw_anchor and not anchor or raw_file:find('?',1,true) then return nil,'invalid' end
    if external(file) then return nil,'external' end
    if file=='' and (not anchor or anchor=='') then return nil,'empty' end
    current_uid=tostring(current_uid)
    local current=index.entries[current_uid]
    if not current then return nil,'source_unavailable' end
    local owners
    if file=='' then
        owners={[current_uid]=true}
        -- One original XHTML may have been split into multiple catalog entries.
        if not current.anchors[anchor] then
            owners={}
            for _i,source in ipairs(current.paths) do
                for owner in pairs(index.files[source] or {}) do owners[owner]=true end
            end
        end
    else
        local destinations={}
        if file:sub(1,1)=='/' then
            local candidate=normalize(file)
            if candidate and index.files[candidate] then destinations[candidate]=true end
        elseif current.physical then
            local missing=false
            for _i,source in ipairs(current.paths) do
                local base=source:match('^(.*)/')
                local candidate=normalize((base and base .. '/' or '') .. file)
                if candidate and index.files[candidate] then destinations[candidate]=true else missing=true end
            end
            if missing and next(destinations) then return nil,'ambiguous_source' end
            -- Some API bodies use a complete original archive path as an alias.
            if not next(destinations) then
                local candidate=normalize(file)
                if candidate and index.files[candidate] then destinations[candidate]=true end
            end
        else
            local candidate=normalize(file)
            if candidate and index.files[candidate] then destinations[candidate]=true
            elseif not file:find('/',1,true) then
                local unique=only(index.basenames[file])
                if unique then destinations[unique]=true end
            end
        end
        local destination=only(destinations)
        if not destination then return nil,next(destinations) and 'ambiguous_file' or 'file_unavailable' end
        owners=index.files[destination]
    end
    local matches={}
    for owner in pairs(owners or {}) do
        local target=index.entries[owner]
        if target and (not anchor or anchor=='' or target.anchors[anchor]==1
            or planning and not target.anchors_known) then matches[owner]=true end
    end
    local owner=only(matches)
    if not owner then return nil,next(matches) and 'ambiguous_anchor' or 'anchor_unavailable' end
    local target=index.entries[owner]
    if planning then
        return {uid=owner,anchor=anchor,anchor_verified=not anchor or anchor=='' or target.anchors[anchor]==1},'planned'
    end
    if owner~=current_uid and not target.output then return nil,'not_packaged' end
    local output=owner==current_uid and anchor and anchor~='' and '' or target.output
    if not output then return nil,'not_packaged' end
    if anchor and anchor~='' then output=output .. '#' .. fragment(anchor) end
    return {uid=owner,href=output,anchor=anchor,forward_ref=target.forward[anchor] or false},'mapped'
end
function M.resolve(index,current_uid,raw_href) return resolve(index,current_uid,raw_href,false) end
-- A catalog plan identifies a candidate only; it never asserts that an
-- undownloaded chapter contains the requested anchor.
function M.plan(index,current_uid,raw_href) return resolve(index,current_uid,raw_href,true) end

local function uri_parts(value)
    value=tostring(value or ''):gsub('\\','/')
    if external(value) then return nil end
    local file,anchor=value:match('^(.-)#(.*)$')
    if not file then file=value end
    if file:find('?',1,true) then return nil end
    file=decode(file);anchor=anchor and decode(anchor)
    if not file or value:find('#',1,true) and not anchor then return nil end
    return file,anchor
end
local function uri_key(file,anchor)
    local result=normalize(file)
    if not result then return nil end
    return result .. (anchor and '#' .. anchor or '')
end
function M.rebased_href(render_path,raw_href)
    local file,anchor=uri_parts(M.attribute(raw_href))
    if not file then return nil end
    if file=='' then file=render_path
    elseif file:sub(1,1)~='/' then file=(render_path:match('^(.*)/') or '') .. '/' .. file end
    return uri_key(file,anchor)
end
function M.native_uri_key(render_path,value)
    if type(value)~='string' then return nil end
    local fragment_id=value:match('^#_doc_fragment_0_ (.*)$')
    if fragment_id then
        fragment_id=decode(fragment_id)
        return fragment_id and render_path .. '#' .. fragment_id or nil
    end
    -- Native external/file links have already been URI-decoded and rebased.
    -- Treat this projection as opaque: decoding a literal %2A a second time,
    -- or splitting a decoded # in a filename, would select a different link.
    value=value:gsub('\\','/')
    if external(value) or value:sub(1,1)=='#' or value:find('[%z\1-\31\127]') then return nil end
    value=value:gsub('^/','')
    return value~='' and value or nil
end

-- CREngine currently prefixes cross-file fragments without decoding URI
-- escapes. Keep the EPUB standard URI and normalize only a proven DOM target
-- at navigation time; actual XPath coordinates and source positions stay raw.
function M.native_xpointer(document,pointer)
    if type(pointer)~='string' or pointer:sub(1,1)~='#' or not pointer:find('%%') then return pointer end
    if not document or type(document.isXPointerInDocument)~='function' then return pointer end
    local target=decode(pointer:sub(2))
    if not target or '#' .. target==pointer then return pointer end
    local candidate='#' .. target
    local ok,exists=pcall(document.isXPointerInDocument,document,candidate)
    return ok and exists and candidate or pointer
end
return M
