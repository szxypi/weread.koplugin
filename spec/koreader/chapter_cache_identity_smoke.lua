-- The profile and all books in this fixture are synthetic.
return function(reader,host,book,id,pump,clean,set_offline)
    local Content=require('weread.lib.content')
    local Identity=require('weread.lib.book_file_identity')
    local Source=require('weread.lib.position_source')
    local Paths=require('weread.lib.chapter_cache_path')
    local Archive=require('weread.lib.source_archive')
    local fs=require('libs/libkoreader-lfs')
    local path=assert(reader.document.file)
    local dir=assert(path:match('^(.*)/[^/]+$'))
    local function bytes(file)
        local input=assert(io.open(file,'rb'));local value=assert(input:read('*a'));input:close();return value
    end
    local original=bytes(path)
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'chapter_cache_claim_smoke.lua')(reader,host,book,id,path,dir,pump)
    local legacy=dir..'/synthetic-legacy.epub'
    local output=assert(io.open(legacy,'wb'));assert(output:write(original));output:close()
    local sidecar=dir..'/synthetic-legacy.sdr';assert(fs.mkdir(sidecar))
    output=assert(io.open(sidecar..'/notes-marker','wb'));assert(output:write('keep'));output:close()
    local copy={};for key,value in pairs(book) do copy[key]=value end
    copy.cached_chapters={['2']=legacy};copy.cached_full_book=nil
    local chapter={chapterUid=2,title='合成重复章节'}
    assert(Paths.plan(copy,chapter,dir).path==legacy,'verified legacy chapter was not reused')
    copy.cached_chapters['4']=legacy
    assert(Paths.plan(copy,chapter,dir).path~=legacy,'shared legacy path was reused')
    copy.cached_chapters['4']=nil
    assert(Content.save_chapter_epub(host.settings,copy,chapter,'<p>synthetic update</p>',{},'',Identity.capture(copy))==legacy)
    assert(bytes(sidecar..'/notes-marker')=='keep' and bytes(path)==original,'legacy update changed other reading data')
    local chapters=assert(host:ensureChaptersLoaded(book))
    local finished
    host:confirmAndDownloadChapters(book,{chapters[1],chapters[3]},'chapters',{
        separate_chapters=true,offer_read=false,on_complete=function(ok) finished=ok and 'ok' or 'failed' end})
    pump(function() return finished~=nil end);assert(finished=='ok','duplicate-title batch download failed')
    local saved=assert(host.settings:get_book(id));local one,three=saved.cached_chapters['1'],saved.cached_chapters['3']
    assert(one and three and one~=three and one~=path and three~=path,'batch chapters shared a file')
    for _,item in ipairs({{one,'1'},{three,'3'}}) do
        local member=Source.meta_path(item[2])
        local headers=assert(Archive.read(item[1],{[Identity.PATH]=Identity.MAX_BYTES,[member]=Source.MAX_META_BYTES}))
        local identity=assert(Identity.decode(headers[Identity.PATH]));local meta=assert(Source.decode_metadata(headers[member]))
        assert(identity.book_id==id and meta.book_id==id and meta.chapter_uid==item[2] and meta.file_id==identity.file_id)
    end
    assert(bytes(path)==original and reader.document.file==path,'batch changed the open chapter')
    clean(reader)
    return dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'combined_chapter_navigation_smoke.lua')(
        reader,host,book,id,pump,clean,set_offline)
end
