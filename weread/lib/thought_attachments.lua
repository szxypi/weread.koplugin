-- Recognize the observed WeRead image bucket; never accept arbitrary hosts.
-- URLs and attachment state are account-local note data, not log output.
local M={MAX_IMAGES=9,MAX_URL=4096}
local HOST='weread-picture-1258476243.file.myqcloud.com'
function M.allowed(value)
    if type(value)~='string' or #value<1 or #value>M.MAX_URL or value:find('[%z%c%s\\#]') then return nil end
    local authority,path=value:match('^https://([^/]+)(/.*)$')
    if not authority or authority:lower()~=HOST or not path or #path<2 then return nil end
    return value
end
function M.decode(value)
    if type(value)~='string' or #value> M.MAX_IMAGES*(M.MAX_URL+1) then return nil end
    local out,seen={},{}
    if value=='' then return out end
    if value:sub(-1)=='\n' then return nil end
    for url in (value..'\n'):gmatch('(.-)\n') do
        if not M.allowed(url) or seen[url] or #out>=M.MAX_IMAGES then return nil end
        seen[url]=true;out[#out+1]=url
    end
    return out
end
function M.cached(value)
    if value.attachment_state==nil and value.attachment_urls==nil and value.attachment_digest==nil then return nil end
    if value.attachment_state~='available' and value.attachment_state~='partial' then error('thought_attachment/state',0) end
    local urls=M.decode(value.attachment_urls)
    if not urls or value.attachment_state=='available' and #urls==0 then error('thought_attachment/state',0) end
    if value.attachment_digest~=nil and (type(value.attachment_digest)~='string' or #value.attachment_digest~=64
        or not value.attachment_digest:match('^[a-f0-9]+$')) then error('thought_attachment/digest',0) end
    return {state=value.attachment_state,urls=value.attachment_urls,digest=value.attachment_digest}
end
function M.project(value,present,options)
    local urls,seen,unknown={}, {},false
    local function add(url)
        if not M.allowed(url) then unknown=true;return end
        if seen[url] then return end
        if #urls>=M.MAX_IMAGES then unknown=true;return end
        seen[url]=true;urls[#urls+1]=url
    end
    if present(value.pictures) then
        local pictures=value.pictures
        if type(pictures)~='table' then unknown=true
        else
            local count=0
            for key in pairs(pictures) do
                if type(key)~='number' or key%1~=0 or key<1 or key>#pictures then unknown=true end
                count=count+1;if count>100 then unknown=true;break end
            end
            if count~=#pictures then unknown=true end
            for index=1,math.min(#pictures,100) do
                local item=pictures[index]
                if type(item)=='table' and present(item.url) then add(item.url) else unknown=true end
            end
        end
    end
    if present(value.pencilNote) then
        local pencil=value.pencilNote
        if type(pencil)~='table' then unknown=true
        else
            local main=pencil.imageUrl
            if present(main) and main~='' then add(main) else unknown=true end
            for _,key in ipairs({'drawingUrl','andDrawingUrl','doddleDrawingUrl'}) do
                if present(pencil[key]) and pencil[key]~='' and pencil[key]~=main then unknown=true end
            end
        end
    end
    if type(value.htmlContent)=='string' and value.htmlContent:lower():find('<img',1,true) then unknown=true end
    if #urls==0 and not unknown then return nil end
    local digest=options and require('weread.lib.thought_attachment_fingerprint').compute(value,present,options.array_mt)
    return {state=unknown and 'partial' or 'available',urls=table.concat(urls,'\n'),digest=digest}
end
return M
