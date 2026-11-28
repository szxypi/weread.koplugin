-- Reproduce an old title collision using isolated, synthetic cached files.
return function(reader,host,book,id,path,dir,pump)
    local Content=require('weread.lib.content')
    local Identity=require('weread.lib.book_file_identity')
    local Claims=require('weread.lib.chapter_cache_claim')
    local chapters=assert(host:ensureChaptersLoaded(book))
    local shadow={};for key,value in pairs(book) do shadow[key]=value end
    shadow.cached_chapters={['2']=path,['4']=path};shadow.cached_file=path;shadow.cached_full_book=nil
    shadow.chapters=chapters;shadow.chapter_uid=4;shadow.chapter_idx=4
    shadow.pending_upload_position=nil;shadow.last_local_position=nil;shadow.unindexed_resume=nil;shadow.cb_cloud_view_resume=nil
    local status=Claims.inspect(shadow,path)
    assert(status.kind=='single' and status.uid=='2','wrong underlying chapter identity')
    assert(not host:getFullBookCachePath(shadow),'shared single chapter mistaken for a full book')
    local index,chapter,full=host:getChapterInfoFromFile(shadow,path)
    assert(index==2 and tostring(chapter.chapterUid)=='2' and not full,'single chapter could not be identified')
    shadow.cached_full_book=path;assert(not host:getFullBookCachePath(shadow),'overwritten full book was trusted')
    shadow.cached_full_book=nil
    local old_open,old_confirm,old_intent=host.openFile,host.confirmAndDownloadChapters,host._chapter_open_intent
    local opened,confirmation
    host.openFile=function(_,target) opened=target end
    host.confirmAndDownloadChapters=function(_,_,selected,_,options) confirmation={selected=selected,options=options} end
    host:openChapter(shadow,chapters[4])
    assert(not opened and confirmation and tostring(confirmation.selected[1].chapterUid)=='4'
        and confirmation.options.confirmation_text,'wrong chapter opened without a download warning')
    confirmation=nil;host:openChapter(shadow,chapters[2]);assert(opened==path and not confirmation)
    opened=nil
    local available,reason,uid=host:openBookForReading(shadow,true,{prefer_exact=true})
    assert(not available and reason=='resume_not_cached' and uid=='4' and not opened,
        'collision silently replaced the last reading chapter')
    assert(host:openBookForReading(shadow,true) and opened==path,'verified alternate chapter was lost')
    local unknown=dir..'/synthetic-unverified.epub'
    local file=assert(io.open(unknown,'wb'));assert(file:write('not an EPUB'));file:close()
    shadow.cached_file=unknown;shadow.cached_chapters={['2']=unknown,['4']=unknown};opened=nil
    available,reason=host:openBookForReading(shadow,true,{prefer_exact=true})
    assert(not available and reason=='ambiguous_cache' and not opened,'unverified cache was opened')
    shadow.chapter_uid=nil;shadow.chapter_idx=nil
    available,reason=host:openBookForReading(shadow,true)
    assert(not available and reason=='ambiguous_cache' and not opened,'unverified cache without a position lost its warning')
    shadow.chapter_uid=4;shadow.chapter_idx=4
    confirmation=nil;host:openChapter(shadow,chapters[4]);assert(not opened and confirmation)
    local combined_book={};for key,value in pairs(book) do combined_book[key]=value end
    combined_book.cache_dir=dir
    local combined=Content.save_book_epub(host.settings,combined_book,{chapters[2],chapters[4]},
        {['2']='<p>synthetic second</p>',['4']='<p>synthetic fourth</p>'},'synthetic-combined',{},'',
        '\137PNG\r\n\026\nsynthetic',Identity.capture(combined_book))
    shadow.cached_file=combined;shadow.cached_chapters={['2']=combined,['4']=combined};shadow.cached_full_book=nil
    assert(Claims.inspect(shadow,combined).kind=='combined' and host:getFullBookCachePath(shadow)==combined,
        'verified legacy combined book was rejected')
    shadow.cached_full_book=combined
    assert(host:getFullBookCachePath(shadow)==combined,'verified full-book cache was rejected')
    local archive=require('weread.lib.source_archive')
    local read_archive=archive.read
    local proof_reads=0
    function archive.read(candidate,wanted,...)
        if candidate==combined and wanted['OEBPS/content.opf'] then proof_reads=proof_reads+1 end
        return read_archive(candidate,wanted,...)
    end
    local combined_index,combined_chapter,is_combined,partial=host:getChapterInfoFromFile(shadow,combined)
    assert(not combined_index and not combined_chapter and is_combined and partial and proof_reads==1,
        'the reader reread the combined archive or skipped checking the opened document')
    proof_reads=0
    local navigation=require('weread.ui.combined_chapter_navigation')
    local open_combined=navigation.open
    local selected_combined
    navigation.open=function(_,_,target,candidate,_current,proof)
        selected_combined=candidate==combined and target==chapters[2] and proof.items.chapter_2
        return selected_combined
    end
    assert(host:openChapter(shadow,chapters[2]) and selected_combined and proof_reads==1,
        'opening a combined chapter reread the archive or lost the verified target')
    navigation.open=open_combined
    proof_reads=0
    host:showSavedChapters(id,nil,{is_current=function() return true end,load_book=function() return shadow end})
    local downloaded=assert(host._saved_chapter_menu)
    assert(#downloaded.item_table==2 and proof_reads==1,
        'the downloaded chapter list reread the archive or showed an absent chapter')
    require('ui/uimanager'):close(downloaded)
    shadow.chapter_uid=5;shadow.chapter_idx=5;opened=nil
    available,reason,uid=host:openBookForReading(shadow,true,{prefer_exact=true})
    assert(not available and reason=='resume_not_cached' and uid=='5' and not opened,
        'combined cache silently replaced a missing resume chapter')
    shadow.chapters={};shadow.chapter_uid=nil;shadow.chapter_idx=5
    available,reason,uid=host:openBookForReading(shadow,true,{prefer_exact=true})
    assert(not available and reason=='resume_not_cached' and uid=='5' and not opened,
        'missing in-memory catalog lost the resume chapter index')
    shadow.chapters=chapters;shadow.cached_chapters={};shadow.cached_file=nil
    proof_reads=0
    available,reason,uid=host:openBookForReading(shadow,true,{prefer_exact=true})
    assert(not available and reason=='resume_not_cached' and uid=='5' and not opened and proof_reads==1,
        'unshared combined cache was not checked or silently replaced the original chapter')
    shadow.chapter_uid=4;shadow.chapter_idx=4
    assert(host:openBookForReading(shadow,true,{prefer_exact=true}) and opened==combined,
        'unshared combined cache lost an available resume chapter')
    opened=nil;shadow.chapter_uid=nil;shadow.chapter_idx=nil;proof_reads=0
    assert(host:openBookForReading(shadow,true,{prefer_exact=true}) and opened==combined and proof_reads==0,
        'opening a combined book without a saved position unnecessarily inspected the archive')
    archive.read=read_archive
    local exact=Content.save_chapter_epub(host.settings,combined_book,chapters[5],
        '<p>synthetic fifth</p>',{},'',Identity.capture(combined_book))
    opened=nil;shadow.chapter_uid=5;shadow.chapter_idx=5;shadow.cached_chapters={['5']=exact}
    assert(host:openBookForReading(shadow,true,{prefer_exact=true}) and opened==exact,
        'a downloaded copy of the target chapter was ignored')
    opened=nil;shadow.cached_full_book=nil;shadow.chapters={chapters[2]};shadow.cached_chapters['2']=path
    assert(host:openBookForReading(shadow,true,{prefer_exact=true}) and opened==exact,
        'stale catalog replaced an available exact chapter')
    local damaged=dir..'/synthetic-truncated.epub'
    local input=assert(io.open(combined,'rb'))
    local incomplete=assert(input:read('*a')):sub(1,-23)
    assert(input:close())
    file=assert(io.open(damaged,'wb'));assert(file:write(incomplete));assert(file:close())
    shadow.cached_full_book=damaged
    shadow.chapters=chapters
    opened=nil
    assert(host:openBookForReading(shadow,true,{prefer_exact=true}) and opened==exact,
        'a truncated full EPUB prevented opening the exact saved chapter')
    opened=nil;shadow.cached_full_book=nil;shadow.cached_chapters['5']=damaged
    available,reason,uid=host:openBookForReading(shadow,true,{prefer_exact=true})
    assert(not available and reason=='resume_not_cached' and uid=='5' and not opened,
        'a truncated target EPUB bypassed the fallback confirmation')
    assert(host:openBookForReading(shadow,true,{prefer_exact=true,confirmed_missing_uid='5'}) and opened==path,
        'the confirmed fallback did not open the remaining chapter')
    opened=nil;shadow.cached_chapters['2']=nil
    available,reason=host:openBookForReading(shadow,true,{prefer_exact=true})
    assert(not available and reason=='damaged_cache' and not opened,'unreadable EPUB was dispatched to the reader')
    local kept=assert(io.open(damaged,'rb'));assert(kept:read('*a')==incomplete);assert(kept:close())
    print('PASS: truncated standard EPUB resume, guarded fallback and file preservation')

    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    local damage_member=dofile(fixtures..'epub_member_damage.lua')
    local damaged_body=dir..'/synthetic-bad-body.epub'
    damage_member(exact,damaged_body,'OEBPS/text/chapter.xhtml',false)
    shadow.cached_chapters={['2']=path,['5']=damaged_body}
    opened=nil
    available,reason,uid=host:openBookForReading(shadow,true,{prefer_exact=true})
    assert(not available and reason=='resume_not_cached' and uid=='5' and not opened,
        'a failed chapter CRC bypassed the fallback confirmation')
    assert(host:openBookForReading(shadow,true,{prefer_exact=true,confirmed_missing_uid='5'}) and opened==path)
    local missing_body=dir..'/synthetic-missing-body.epub'
    damage_member(combined,missing_body,'OEBPS/text/chapter-002.xhtml',true)
    shadow.cached_full_book=missing_body;shadow.cached_chapters={['2']=path}
    shadow.chapter_uid=4;shadow.chapter_idx=4;opened=nil
    available,reason,uid=host:openBookForReading(shadow,true,{prefer_exact=true})
    assert(not available and reason=='resume_not_cached' and uid=='4' and not opened,
        'the combined EPUB claimed a chapter whose rendered body was missing')
    assert(host:openBookForReading(shadow,true,{prefer_exact=true,confirmed_missing_uid='4'}) and opened==path)
    confirmation=nil;opened=nil
    assert(not host:openChapter(shadow,chapters[4],nil,{cached_only=true}) and not opened and not confirmation,
        'manual offline chapter selection ignored a missing rendered body')
    shadow.cached_chapters['2']=missing_body
    available,reason=host:openBookForReading(shadow,true,{prefer_exact=true})
    assert(not available and reason=='damaged_cache' and not opened,
        'automatic fallback reused the combined file at the same damaged position')
    local opened_intact=false
    navigation.open=function(_,_,target,candidate)
        opened_intact=target==chapters[2] and candidate==missing_body
        return opened_intact
    end
    assert(host:openChapter(shadow,chapters[2],nil,{cached_only=true}) and opened_intact,
        'manual selection could not open the intact chapter of the combined file')
    navigation.open=open_combined
    print('PASS: intact ZIP with a corrupt or missing rendered chapter body')
    shadow.chapters=chapters;shadow.chapter_uid=4;shadow.chapter_idx=4
    host.openFile,host.confirmAndDownloadChapters,host._chapter_open_intent=old_open,old_confirm,old_intent
    -- Confirm the real recovery download without opening another reader, then
    -- remove only its synthetic cache mapping for the rest of this fixture.
    shadow.cached_file=path;shadow.cached_full_book=nil;shadow.cached_chapters={['2']=path,['4']=path}
    local old_start=host.downloader.start
    local completed
    host.downloader.start=function(self,download_book,selected,suffix,options)
        local done=options.on_complete
        options.offer_read=false
        options.on_complete=function(ok,new_path)
            if done then done(ok,new_path) end
            completed=ok and new_path or false
        end
        return old_start(self,download_book,selected,suffix,options)
    end
    host:openChapter(shadow,chapters[4])
    pump(function() return completed~=nil and not host.downloader._active_job end)
    host.downloader.start=old_start
    assert(completed and completed~=path,'collision recovery did not save a distinct chapter')
    local Source=require('weread.lib.position_source')
    local member=Source.meta_path('4')
    local headers=assert(require('weread.lib.source_archive').read(completed,
        {[Identity.PATH]=Identity.MAX_BYTES,[member]=Source.MAX_META_BYTES}))
    local recovered_identity=assert(Identity.decode(headers[Identity.PATH]))
    local recovered=assert(Source.decode_metadata(headers[member]))
    assert(recovered_identity.book_id==id and recovered.book_id==id and recovered.chapter_uid=='4'
        and recovered.file_id==recovered_identity.file_id,'recovery saved the wrong chapter')
    local updated=assert(host.settings:get_book(id))
    assert(updated.cached_chapters['4']==completed and updated.cached_chapters['2']==path)
    local saved=host.settings:get('books',{});updated.cached_chapters['4']=nil;saved[id]=updated
    host.settings:set('books',saved);host.settings:flush()
    host._chapter_open_intent=old_intent
    assert(reader.document.file==path)
end
