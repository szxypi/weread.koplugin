-- Localize only positively identified in-package resources. Unknown references
-- are reported to the caller; this module never opens a URL or a filesystem path.
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local M={MAX_BYTES=8*1024*1024,MAX_ASSETS=2048,MAX_REMOTE=64}
local function fail(reason) error('native_resources/'..reason,0) end
local function array(value,maximum)
    if type(value)~='table' then return false end
    local count=0
    for key in pairs(value) do
        if type(key)~='number' or key%1~=0 or key<1 or key>maximum then return false end
        count=count+1
    end
    for i=1,count do if value[i]==nil then return false end end
    return count<=maximum
end
local function valid_text(value)
    return type(value)=='string' and #value<=M.MAX_BYTES and not value:find('[%z\1-\8\11\12\14-\31]')
        and Protocol.utf8_substr(value,#value)==value
end
local function clean(value)
    if type(value)~='string' or #value==0 or #value>4096 or value:find('[%z%c\\]') then return nil end
    value=value:gsub('&amp;','&'):match('^[^%?#]*')
    if value:gsub('%%(%x%x)',''):find('%',1,true) then return nil end
    value=value:gsub('%%(%x%x)',function(hex) return string.char(tonumber(hex,16)) end)
    if value:find('[%z%c\\]') then return nil end
    local parts={}
    for part in value:gmatch('[^/]+') do
        if part=='..' then
            if #parts>0 and parts[#parts]~='..' then parts[#parts]=nil else parts[#parts+1]=part end
        elseif part~='.' and part~='' then parts[#parts+1]=part end
    end
    return table.concat(parts,'/')
end
local function lookup(index,owner,reference)
    local value=reference:match('^%s*(.-)%s*$') or ''
    local lower=value:lower()
    if lower:match('^data:') or value:sub(1,1)=='#' then return value,'embedded' end
    if lower:match('^https?://') or value:sub(1,2)=='//' then
        local key=value:gsub('&amp;','&')
        local href=index.remote and index.remote[key]
        if href==false then return nil,'ambiguous' end
        if href then return href,'local' end
        return value,'remote',key
    end
    if lower:match('^[%a][%w+.-]*:') or value:sub(1,1)=='/' then return nil,'unsupported' end
    local ref=clean(value)
    if not ref or ref=='' then return nil,'unsupported' end
    local parent=owner:match('^(.*)/[^/]*$') or ''
    local resolved=clean((parent~='' and parent..'/' or '')..ref)
    local href=resolved and index.exact[resolved]
    if href==false then return nil,'ambiguous' end
    return href,href and 'local' or 'missing'
end
local function index_assets(assets,remote_assets)
    if not array(assets,M.MAX_ASSETS) then fail('assets') end
    if not array(remote_assets,M.MAX_REMOTE) then fail('assets') end
    local index={exact={},remote={},output={},seen={}}
    local total=0
    local function add_assets(rows,remote)
    for _,asset in ipairs(rows) do
        if type(asset)~='table' or type(asset.source)~='string' or type(asset.data)~='string'
            or #asset.data==0 or #asset.data>M.MAX_BYTES then fail('asset') end
        total=total+#asset.data
        if total>64*1024*1024 then fail('assets') end
        local path=remote and asset.source or clean(asset.source)
        local ext=({['image/png']='.png',['image/jpeg']='.jpg',['image/gif']='.gif',['image/webp']='.webp'})[asset.media_type]
        if not path or path=='' or not ext then fail('asset') end
        local data=asset.data
        local signature=(asset.media_type=='image/png' and data:sub(1,8)=='\137PNG\r\n\26\n')
            or (asset.media_type=='image/jpeg' and data:sub(1,3)=='\255\216\255')
            or (asset.media_type=='image/gif' and (data:sub(1,6)=='GIF87a' or data:sub(1,6)=='GIF89a'))
            or (asset.media_type=='image/webp' and data:sub(1,4)=='RIFF' and data:sub(9,12)=='WEBP')
        if not signature then fail('asset') end
        local digest=Crypto.sha256_hex(asset.data)
        local href='images/eink-'..digest..ext
        local function add(map,key)
            if map[key]==nil then map[key]=href elseif map[key]~=href then map[key]=false end
        end
        if remote then
            if not path:lower():match('^https?://') and path:sub(1,2)~='//' then fail('asset') end
            add(index.remote,path:gsub('&amp;','&'))
        else add(index.exact,path) end
        if not index.seen[href] then
            index.seen[href]=true
            index.output[#index.output+1]={href=href,media_type=asset.media_type,data=asset.data}
        end
    end
    end
    add_assets(assets,false)
    add_assets(remote_assets,true)
    return index
end
local function record_remote(summary,key)
    summary.remote=summary.remote+1
    if not summary.remote_seen[key] then
        if #summary.remote_urls>=M.MAX_REMOTE then fail('remote_limit') end
        summary.remote_seen[key]=true
        summary.remote_urls[#summary.remote_urls+1]=key
    end
end

-- Inline declarations with ordinary layout and typography values have no
-- external references. Keep them verbatim; complex CSS remains unverified and
-- must not silently bypass resource localization.
local INLINE_PROPERTIES={
    width=true,height=true,['max-width']=true,['min-width']=true,['max-height']=true,['min-height']=true,
    margin=true,['margin-top']=true,['margin-right']=true,['margin-bottom']=true,['margin-left']=true,
    padding=true,['padding-top']=true,['padding-right']=true,['padding-bottom']=true,['padding-left']=true,
    color=true,['background-color']=true,['font-size']=true,['font-weight']=true,['font-style']=true,
    ['font-family']=true,['line-height']=true,['text-align']=true,['text-indent']=true,['text-decoration']=true,
    ['vertical-align']=true,display=true,['white-space']=true,['word-break']=true,['letter-spacing']=true,
    ['border-width']=true,['border-style']=true,['border-color']=true,['page-break-before']=true,['page-break-after']=true,
}
local function plain_inline_style(value)
    if not valid_text(value) or value:find('[&\\@<>(){}]') or value:find('/*',1,true) then return false end
    for declaration in (value..';'):gmatch('(.-);') do
        if declaration:match('%S') then
            local property,content=declaration:match('^%s*([%a][%w%-]*)%s*:%s*(.-)%s*$')
            if not property or not INLINE_PROPERTIES[property:lower()] or content==''
                or content:find('[^%w%s%.,%%#_%-%+!\'"]') then return false end
        end
    end
    return true
end

local function check_inline_style(tag)
    if not tag:lower():match('%sstyle%s*=') then return end
    local count=0
    tag:gsub('([%w_:%-]+)(%s*=%s*)(["\'])(.-)%3',function(key,_equals,_quote,value)
        if key:lower()=='style' then
            count=count+1
            if count>1 or not plain_inline_style(value) then fail('inline_style') end
        end
    end)
    if count~=1 then fail('inline_style') end
end
local function css_rewrite(css,owner,index,prefix,summary)
    if not valid_text(css) then fail('css') end
    if css:lower():find('@import',1,true) then fail('css_import') end
    local out,at,start={},1,1
    while at<=#css do
        local c=css:sub(at,at)
        if c=='/' and css:sub(at,at+1)=='/*' then
            local ending=css:find('*/',at+2,true)
            if not ending then fail('css') end
            at=ending+2
        elseif c=='"' or c=="'" then
            local quote=c;at=at+1
            while at<=#css and css:sub(at,at)~=quote do
                if css:sub(at,at)=='\\' then at=at+1 end
                at=at+1
            end
            if at>#css then fail('css') end
            at=at+1
        elseif css:sub(at,at+2):lower()=='url' and (at==1 or not css:sub(at-1,at-1):match('[%w_%-]')) then
            local suffix=css:sub(at+3):match('^%s*%(')
            if not suffix then at=at+1 else
                local value_start=at+3+#suffix
                local cursor=value_start
                while css:sub(cursor,cursor):match('%s') do cursor=cursor+1 end
                local quote=css:sub(cursor,cursor)
                local raw,closing
                if quote=='"' or quote=="'" then
                    local ending=css:find(quote,cursor+1,true)
                    if not ending then fail('css_url') end
                    raw=css:sub(cursor+1,ending-1)
                    local suffix_end=css:sub(ending+1):match('^%s*%)')
                    if not suffix_end then fail('css_url') end
                    closing=ending+#suffix_end
                else
                    closing=css:find(')',cursor,true)
                    if not closing then fail('css_url') end
                    raw=css:sub(cursor,closing-1):match('^%s*(.-)%s*$')
                end
                if raw:find('[\\"\']') or raw:find('%(') then fail('css_url') end
                local href,kind,key=lookup(index,owner,raw)
                if not href then fail(kind) end
                if kind=='remote' then record_remote(summary,key)
                elseif kind=='local' then href=prefix..href;summary.localized=summary.localized+1 end
                out[#out+1]=css:sub(start,at-1)..'url("'..href..'")'
                at=closing+1;start=at
            end
        else at=at+1 end
    end
    out[#out+1]=css:sub(start)
    return table.concat(out)
end
local function tag_end(text,start)
    local quote
    for pos=start,#text do
        local c=text:sub(pos,pos)
        if quote then if c==quote then quote=nil end
        elseif c=='"' or c=="'" then quote=c
        elseif c=='>' then return pos end
    end
    fail('html')
end
local function html_rewrite(body,owner,index,style_index,summary)
    if not valid_text(body) then fail('body') end
    local out,at={},1
    while at<=#body do
        local start=body:find('<',at,true)
        if not start then out[#out+1]=body:sub(at);break end
        out[#out+1]=body:sub(at,start-1)
        if body:sub(start,start+3)=='<!--' then
            local ending=body:find('-->',start+4,true)
            if not ending then fail('html') end
            out[#out+1]=body:sub(start,ending+2);at=ending+3
        else
            local ending=tag_end(body,start+1)
            local tag=body:sub(start,ending)
            local name=tag:match('^<%s*([%a][%w:%-]*)')
            name=name and name:lower()
            if name=='link' then
                local attrs={}
                local remainder=tag:gsub('([%w_:%-]+)(%s*=%s*)(["\'])(.-)%3',function(key,_equals,_quote,value)
                    key=key:lower()
                    if attrs[key]~=nil then fail('ambiguous') end
                    attrs[key]=value
                    return ''
                end):gsub('^<%s*[Ll][Ii][Nn][Kk]',''):gsub('/?%s*>$','')
                if remainder:match('%S') or type(attrs.href)~='string' or type(attrs.rel)~='string'
                    or attrs.rel:lower()~='stylesheet' or attrs.type and attrs.type:lower()~='text/css' then
                    fail('link_tag')
                end
                for key in pairs(attrs) do if key~='href' and key~='rel' and key~='type' then fail('link_tag') end end
                local style,kind=lookup(style_index,owner,attrs.href)
                if kind~='local' then fail('link_tag') end
                summary.style_links[#summary.style_links+1]=style
                tag=''
            end
            if name=='style' then fail('style_tag') end
            if name=='script' or name=='iframe' or name=='object' or name=='embed' or name=='video' or name=='audio'
                or name=='source' or name=='picture' then fail('unsupported_markup') end
            local lower_tag=tag:lower()
            for _,attribute in ipairs({'background','poster'}) do
                if lower_tag:match('%s'..attribute..'%s*=') then fail('background_attribute') end
            end
            if name=='img' or name=='image' then
                local seen,found={},false
                for _,attribute in ipairs({'srcset','data%-src','data%-original','data%-lazy%-src'}) do
                    if lower_tag:match('%s'..attribute..'%s*=') then fail('unsupported_markup') end
                end
                tag=tag:gsub('([%w_:%-]+)(%s*=%s*)(["\'])(.-)%3',function(key,equals,quote,value)
                    local lower=key:lower()
                    if lower=='srcset' or lower=='data-src' or lower=='data-original' or lower=='data-lazy-src' then
                        fail('unsupported_markup')
                    end
                    local resource=(name=='img' and lower=='src') or (name=='image' and (lower=='href' or lower=='xlink:href'))
                    if resource then
                        if seen[lower] or found then fail('ambiguous') end
                        seen[lower],found=true,true
                        local href,kind,remote_key=lookup(index,owner,value)
                        if not href then fail(kind) end
                        if kind=='remote' then record_remote(summary,remote_key)
                        elseif kind=='local' then href='../'..href;summary.localized=summary.localized+1 end
                        return key..equals..quote..href..quote
                    end
                end)
                if not found then fail('unsupported_markup') end
            elseif name and lower_tag:match('%s[%w_:%-]*src[%w_:%-]*%s*=') then
                fail('other_source_attribute')
            end
            check_inline_style(tag)
            out[#out+1]=tag;at=ending+1
        end
    end
    return table.concat(out)
end

-- Combining separate CSS files is safe only at rule boundaries. At-rules can
-- have sheet-level ordering semantics, so keep those on the existing path.
local function concatenable(css)
    if not valid_text(css) then return false end
    local at,depth,boundary=1,0,true
    while at<=#css do
        local c=css:sub(at,at)
        if c=='/' and css:sub(at,at+1)=='/*' then
            local ending=css:find('*/',at+2,true)
            if not ending then return false end
            at=ending+2
        elseif c=='"' or c=="'" then
            if depth==0 then boundary=false end
            local quote=c;at=at+1
            while at<=#css and css:sub(at,at)~=quote do
                if css:sub(at,at)=='\\' then at=at+1 end
                at=at+1
            end
            if at>#css then return false end
            at=at+1
        elseif c=='\\' then
            if at==#css then return false end
            if depth==0 then boundary=false end
            at=at+2
        elseif c=='@' then return false
        elseif c=='{' then depth=depth+1;boundary=false;at=at+1
        elseif c=='}' then
            depth=depth-1;if depth<0 then return false end
            if depth==0 then boundary=true end
            at=at+1
        else
            if depth==0 and not c:match('%s') then boundary=false end
            at=at+1
        end
    end
    return depth==0 and boundary
end

function M.prepare(value,remote_assets)
    local ok,result=pcall(function()
        if type(value)~='table' or value.source_channel~='eink' or value.coordinate_source_authoritative~=false
            or value.is_text~=false or not array(value.body_parts,2048) or #value.body_parts==0
            or not array(value.style_parts,2048) or not valid_text(value.body) or not valid_text(value.css)
            or type(value.unusable_resources)~='number' or value.unusable_resources<0
            or value.unusable_resources%1~=0 or value.unusable_resources>2048 then fail('source') end
        local index=index_assets(value.assets,remote_assets or {})
        local style_index={exact={}}
        for _,part in ipairs(value.style_parts) do
            if type(part)~='table' or type(part.source)~='string' then fail('css') end
            local path=clean(part.source)
            if not path or path=='' or style_index.exact[path] then fail('css') end
            if #value.style_parts>1 and not concatenable(part.data) then fail('multiple_styles') end
            style_index.exact[path]=path
        end
        local summary={localized=0,remote=0,remote_urls={},remote_seen={},style_links={}}
        local bodies,styles,style_order={}, {}, nil
        for _,part in ipairs(value.body_parts) do
            if type(part)~='table' or type(part.source)~='string' then fail('body') end
            summary.style_links={}
            bodies[#bodies+1]=html_rewrite(part.data,part.source,index,style_index,summary)
            if #value.style_parts>1 then
                local links=summary.style_links
                if #links~=#value.style_parts then fail('multiple_styles') end
                local seen={}
                for link_index,path in ipairs(links) do
                    if seen[path] or style_order and style_order[link_index]~=path then fail('multiple_styles') end
                    seen[path]=true
                end
                if not style_order then style_order=links end
            end
        end
        local by_path={}
        for _,part in ipairs(value.style_parts) do
            if type(part)~='table' or type(part.source)~='string' then fail('css') end
            local result=css_rewrite(part.data,part.source,index,'',summary)
            styles[#styles+1]=result
            by_path[clean(part.source)]=result
        end
        if style_order then
            styles={}
            for _,path in ipairs(style_order) do styles[#styles+1]=by_path[path] end
        end
        local original_bodies,original_styles={},{}
        for _,part in ipairs(value.body_parts) do original_bodies[#original_bodies+1]=part.data end
        for _,part in ipairs(value.style_parts) do original_styles[#original_styles+1]=part.data end
        if table.concat(original_bodies,'\n')~=value.body or table.concat(original_styles,'\n')~=value.css then
            fail('source_changed')
        end
        return {xhtml=table.concat(bodies,'\n'),css=table.concat(styles,'\n'),assets=index.output,
            remote_references=summary.remote,localized_references=summary.localized,
            remote_urls=summary.remote_urls,
            unusable_resources=value.unusable_resources,source_channel='eink',coordinate_source_authoritative=false}
    end)
    if not ok then return nil,type(result)=='string' and result:match('^native_resources/[a-z_]+$') or 'native_resources/unavailable' end
    return result
end
return M
