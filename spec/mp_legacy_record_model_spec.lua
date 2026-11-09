package.path='./?.lua;'..package.path
local files,attrs,serial={},{},0
local original_open=io.open
local function node(path,raw)
    serial=serial+1;attrs[path]={mode=raw and 'file' or 'directory',dev=1,ino=serial,size=raw and #raw or 0,modification=1}
    files[path]=raw;return attrs[path]
end
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=function(path,key)
    if attrs[path] then return key and attrs[path][key] or attrs[path] end
    return nil,'missing',2
end} end
package.preload['weread.lib.content']=function() return {
    book_resolved_dir=function(_settings,_id,book) return book.cache_dir end,
    mp_article_legacy_path=function(_settings,book,article) return book.cache_dir..'/'..article.title..'.html' end,
    mp_article_asset_name=function() return '.weread-mp-one-assets' end} end
local resource_inspections=0
package.preload['weread.lib.mp_record_assets']=function() return {
    inspect=function() resource_inspections=resource_inspections+1;return {} end,
    matches=function() return true end,copy=function(_input,_stage,html) return html,0,0 end,
    header=function(html) return html,assert(html:find('<head>',1,true))+5,assert(html:find('</head>',1,true)) end} end
rawset(io,'open',function(path,mode)
    if mode~='rb' or not files[path] then return nil end
    return {read=function(_self,n) return files[path]:sub(1,n) end,close=function() end}
end)
local Model=require('weread.lib.mp_record_recovery')
local Identity=require('weread.lib.mp_cache_identity')
local Versions=require('weread.lib.mp_cache_versions')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    files,attrs={},{};resource_inspections=0
    local article={reviewId='one',title='Legacy'}
    local book={book_id='MP_WXS_1',cache_dir='/root',mp_articles={article}}
    local stored={mp_articles={article}}
    local settings={get=function() return {[book.book_id]=stored} end}
    node('/root');node('/root/Legacy.html','<!DOCTYPE html><html><head><title>Legacy</title></head><body><p>原文</p></body></html>')
    return settings,book,article,stored
end
local settings,book,article=fixture()
local stored
local input=Model.capture(settings,book,article,'/root/Legacy.html')
expect(input.legacy and not input.snapshot and not attrs['/root/mp-articles'],'inspection created a target cache directory')
expect(Model.matches(settings,book,article,input),'unchanged legacy catalog/source did not match')
local prepared=Model.prepare({list=function() return {} end},input)
expect(prepared.ok and #prepared.rows==0 and not prepared.source_sha256 and resource_inspections==0,'ordinary no-record read inspected unneeded resources')
expect(not pcall(Model.prepare,{list=function() return nil end},input),'corrupt archive was treated as empty')
prepared=Model.prepare({list=function() return {{valid=true}} end},input)
expect(prepared.source_sha256==Crypto.sha256_hex(files[input.path]) and resource_inspections==1,'record recovery omitted text/resource preparation')
local parent='/root/mp-articles/'..Identity.key(book,article)
node('/root/mp-articles')
expect(Model.matches(settings,book,article,input),'unrelated article container creation invalidated an absent target')
node(parent)
expect(not Model.matches(settings,book,article,input),'independent target creation did not invalidate the old empty target token')
local stage={root='/root',key=input.key,version_snapshot=Versions.capture('/root',input.key),
    version_name='article-0123456789abcdef.html',output={write=function(self,raw) self.raw=raw;return true end,sync=function() return true end}}
expect(Model.bind_stage(input,stage) and Model.matches(settings,book,article,input),'confirmed first empty stage could not bind')
input.assets={};local receipt=Model.write(input,stage,prepared.source_sha256)
expect(receipt.ok and stage.output.raw:find(Identity.marker(input.key),1,true)
    and stage.output.raw:find('<body><p>原文</p></body>',1,true),'independent copy lost its identity or changed text DOM')
for _i,change in ipairs({'ambiguous','catalog_removed','title','source','root'}) do
    settings,book,article,stored=fixture();input=Model.capture(settings,book,article,'/root/Legacy.html')
    if change=='ambiguous' then stored.mp_articles={{reviewId='one',title='Legacy'},{reviewId='two',title='Legacy'}}
    elseif change=='catalog_removed' then stored.mp_articles=nil elseif change=='title' then article.title='Other'
    elseif change=='source' then node('/root/Legacy.html',files['/root/Legacy.html']) else node('/root') end
    expect(not Model.matches(settings,book,article,input),'stale legacy authority retained: '..change)
end
settings,book,article=fixture();input=Model.capture(settings,book,article,'/root/Legacy.html')
node('/root/mp-articles');node(parent);node(parent..'/article.html','unexpected body')
expect(not Model.bind_stage(input,{root='/root',key=input.key,version_snapshot=Versions.capture('/root',input.key)}),'nonempty target gained authority during stage binding')
settings,book,article=fixture();node('/root/Legacy.epub','synthetic archive')
local value,reason=Model.capture(settings,book,article,'/root/Legacy.epub')
expect(value and value.legacy and value.epub and reason==nil,'legacy EPUB bypassed record protection')
expect(Model.matches(settings,book,article,value) and Model.bind_assets(value,nil) and Model.assets_match(value),'self-contained EPUB required external bitmap authority')
local empty=Model.prepare({list=function() return {} end},value)
expect(empty.ok and #empty.rows==0 and not empty.source_sha256,'no-record EPUB required unnecessary archive parsing')
local archive_calls=0
package.loaded['weread.lib.mp_epub_records']={inspect=function(path,info,key)
    assert(path==value.path and info==value.info and key==value.key);archive_calls=archive_calls+1
    return {source_sha256=string.rep('c',64)}
end,write=function(source,output,nonce,sha)
    assert(source==value and output==stage.output and nonce=='0123456789abcdef' and sha==string.rep('c',64))
    return {ok=true,bytes=100,images=0,image_bytes=0}
end}
prepared=Model.prepare({list=function() return {{valid=true}} end},value)
expect(archive_calls==1 and prepared.source_sha256==string.rep('c',64) and not prepared.assets,'EPUB preparation used the HTML resource parser')
node('/root/mp-articles');node(parent)
stage={root='/root',key=value.key,format='epub',version_snapshot=Versions.capture('/root',value.key),
    version_name='article-0123456789abcdef.epub',output={}}
expect(Model.bind_stage(value,stage) and Model.matches(settings,book,article,value),'first EPUB identity tree did not bind')
expect(Model.write(value,stage,prepared.source_sha256).ok,'EPUB write did not reach the independent archive copier')
stage.format='html'
expect(not pcall(Model.write,value,stage,prepared.source_sha256),'EPUB records were copied into an HTML staging format')
settings,book,article=fixture();node('/root/Legacy.html','<head>'..Identity.marker(string.rep('f',64))..'</head>')
expect(not pcall(Model.capture,settings,book,article,'/root/Legacy.html'),'foreign explicit article identity was promoted by title')
rawset(io,'open',original_open)
print('PASS: legacy catalog and first identity-stage ownership ('..checks..' checks)')
