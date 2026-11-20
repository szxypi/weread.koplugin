package.path='./?.lua;'..package.path
local files,attrs,serial,state={},{},0,{}
local original_open,original_rename=io.open,os.rename
local function info(mode,size)
    serial=serial+1;return {mode=mode,dev=1,ino=serial,size=size or 0,modification=1}
end
local function write(path,raw)
    files[path]=raw;attrs[path]=info('file',#raw)
end
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=function(path,key)
    if attrs[path] then return key and attrs[path][key] or attrs[path] end
    return nil,'missing',2
end} end
package.preload['util']=function() return {htmlEntitiesToUtf8=function(value) return (value:gsub('&amp;','&')) end} end
package.preload['weread.lib.notes_export_file']=function() return {create=function(directory)
    state.created=(state.created or 0)+1
    local path=directory..'/bitmap-20261109-120000-'..state.created..'.html';write(path,'')
    local output={path=path}
    function output:write(raw) if state.write_failed then return false end;files[self.path]=files[self.path]..raw;return true end
    function output:sync() return true end
    function output:accept(size) attrs[self.path].size=#files[self.path];return size==#files[self.path] end
    function output:abort() if self.path then files[self.path]=nil;attrs[self.path]=nil end end
    return output
end} end
rawset(io,'open',function(path,mode)
    if mode~='rb' then return original_open(path,mode) end
    if not files[path] then return nil end
    local at=1
    return {close=function() end,read=function(_self,n)
        if state.replace_on_read and n>32 then attrs[path]=info('file',#files[path]);state.replace_on_read=nil end
        if at>#files[path] then return nil end
        local raw=files[path]:sub(at,at+n-1);at=at+#raw;return raw
    end}
end)
rawset(os,'rename',function(from,to)
    if not files[from] or attrs[to] then return nil end
    files[to],attrs[to]=files[from],attrs[from];files[from],attrs[from]=nil,nil;return true
end)
local Assets=require('weread.lib.mp_record_assets')
local Stage=require('weread.lib.mp_download_stage')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local png='\137PNG\r\n\26\n'..string.rep('S',32)
local function fixture()
    files,attrs,state={},{},{}
    attrs['/root']=info('directory');attrs['/root/.weread-mp-one-assets']=info('directory')
    attrs['/pending']=info('directory');attrs['/pending/images']=info('directory')
    write('/root/.weread-mp-one-assets/img-0001.png',png)
    return {root='/root',root_info=attrs['/root'],asset_name='.weread-mp-one-assets'},
        {directory='/pending',generation='.weread-mp-identity-assets-0123456789abcdef',images_owned=function() return not state.unowned end}
end
local input,stage=fixture()
local html='<!DOCTYPE html><html><head><style>p{line-height:1.7}</style></head><body>'
    ..'<!-- <img src="not-a-resource"> --><script>"<img src=\'ignored\'>"</script><p id="q">原文 &amp; 附注</p>'
    ..'<IMG alt="x > y" SRC = ".weread-mp-one-assets/img-0001.png" width="24" />'
    .."<img src='./.weread-mp-one-assets/img-0001.png'>"
    ..'<img src=".weread-mp-one-assets/img-0002.png"><img src="data:image/png;base64,AAAA">'
    ..'<img src="https://example.invalid/image?a=1&amp;b=2"><a href="#q">回到原文</a></body></html>'
local rows=Assets.inspect(input,html)
expect(#rows==2 and rows[1].info.size==#png and rows[2].info==false,'duplicate or missing bitmap snapshot changed')
input.assets=rows
local copied,images,bytes=Assets.copy(input,stage,html)
local first=stage.generation..'/images/img-0001.png';local absent=stage.generation..'/images/img-0002.png'
expect(images==1 and bytes==#png and files['/pending/images/img-0001.png']==png,'offline copy changed bitmap bytes')
expect(not files['/pending/images/img-0002.png'] and copied:find(absent,1,true),'missing bitmap resolved to an unrelated legacy file')
local expected=html:gsub('%.weread%-mp%-one%-assets/img%-0001%.png',first)
    :gsub('%./'..first:gsub('([^%w])','%%%1'),first):gsub('%.weread%-mp%-one%-assets/img%-0002%.png',absent)
expect(copied==expected,'resource relocation changed text, DOM nodes, quotes, script, or other URLs')
expect(files['/root/.weread-mp-one-assets/img-0001.png']==png,'original bitmap was modified')
for _i,raw in ipairs({'<html><body><p>headless</p></body></html>','<HTML lang="x>y"><BODY>headless</BODY></HTML>',
    '<html><HEAD lang="zh"><title>saved</title></HEAD><body>kept</body></html>'}) do
    local stamped,finish,closing=Assets.header(raw)
    expect(stamped:sub(finish+1,closing-1)==(raw:find('saved',1,true) and '<title>saved</title>' or '')
        and stamped:find(raw:match('(<[bB][oO][dD][yY]>.*)'),1,true),'head insertion altered existing body or header attributes')
end
expect(not pcall(Assets.header,'<html><head>unclosed<body>kept</body></html>'),'unclosed header was accepted')
for _i,raw in ipairs({'<img src="../private.png">','<img src="/private.png">','<img src=".weread-mp-other-assets/img-1.png">',
    '<img src=".weread-mp-one-assets/../private.png">','<img src=".weread-mp-one-assets/img-1.png?x">',
    '<img src=".weread-mp-one-assets/img-1.png" src="duplicate">','<img src="unclosed>',
    '<img srcset=".weread-mp-one-assets/img-1.png 1x">','<base href="/private">','<link href="relative.css">',
    '<style>p{background:url(relative.png)}</style>','<!-- unclosed'}) do
    expect(not pcall(Assets.inspect,input,raw),'unverified or malformed resources accepted')
end
for _i,change in ipairs({'file','directory','root','missing_appears'}) do
    input,stage=fixture();input.assets=Assets.inspect(input,html)
    if change=='file' then attrs['/root/.weread-mp-one-assets/img-0001.png']=info('file',#png)
    elseif change=='directory' then attrs['/root/.weread-mp-one-assets']=info('directory')
    elseif change=='root' then attrs['/root']=info('directory')
    else write('/root/.weread-mp-one-assets/img-0002.png',png) end
    expect(not Assets.matches(input,input.assets) and not pcall(Assets.copy,input,stage,html) and not state.created,
        'changed source copied after preparation: '..change)
end
for _i,change in ipairs({'link','oversize','bad_media'}) do
    input=fixture()
    if change=='link' then attrs['/root/.weread-mp-one-assets/img-0001.png'].mode='link'
    elseif change=='oversize' then attrs['/root/.weread-mp-one-assets/img-0001.png'].size=Stage.MAX_IMAGE+1
    else write('/root/.weread-mp-one-assets/img-0001.png','not an image') end
    expect(not pcall(Assets.inspect,input,html),'invalid source bitmap accepted: '..change)
end
input=fixture();local many={}
for index=1,Stage.MAX_IMAGES+1 do many[index]='<img src=".weread-mp-one-assets/img-'..index..'.png">' end
expect(not pcall(Assets.inspect,input,table.concat(many)),'resource count exceeded its bound')
input=fixture();attrs['/root/.weread-mp-one-assets'].mode='link'
expect(#Assets.inspect(input,'<p>plain text</p>')==0 and Assets.matches(input,{}),'unreferenced asset directory blocked text-only recovery')
input,stage=fixture();input.assets=Assets.inspect(input,html);state.replace_on_read=true
expect(not pcall(Assets.copy,input,stage,html),'replacement during streaming was accepted')
input,stage=fixture();input.assets=Assets.inspect(input,html);state.write_failed=true
expect(not pcall(Assets.copy,input,stage,html) and not files['/pending/images/bitmap-20261109-120000-1.html'],'failed stream retained its partial output')
input,stage=fixture();input.assets=Assets.inspect(input,html);write('/pending/images/img-0001.png','replacement')
expect(not pcall(Assets.copy,input,stage,html) and files['/pending/images/img-0001.png']=='replacement','existing output bitmap was overwritten')
input,stage=fixture();input.assets=Assets.inspect(input,html);state.unowned=true
expect(not pcall(Assets.copy,input,stage,html) and not state.created,'replacement staging directory was used')
rawset(io,'open',original_open);rawset(os,'rename',original_rename)
print('PASS: legacy HTML DOM-preserving bitmap relocation ('..checks..' checks)')
