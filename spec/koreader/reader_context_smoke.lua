-- Packaged Content/Client and actual HTTP/JSON; synthetic download state only.
return function(plugin,count,flush,home)
    local Content=require('weread.lib.content')
    local Protocol=require('weread.lib.protocol')
    local Crypto=require('weread.lib.crypto')
    local tr=require('weread.lib.i18n').tr
    local client,settings=plugin.client,plugin.settings
    local UIManager=require('ui/uimanager')
    local http,ltn12=require('socket.http'),require('ltn12')
    local root=Protocol.reader_url('900001')
    local other=Protocol.reader_url('900002')
    local writes=count('/web/book/read')
    local function control(value)
        local body=client:json_encode(value)
        local _,code=http.request{url=settings.mock_endpoint..'/__control',proxy=settings.mock_endpoint,method='POST',
            headers={['content-type']='application/json',['content-length']=#body},source=ltn12.source.string(body),sink=ltn12.sink.null()}
        assert(code==200)
    end
    local request=client.request
    local captured,wrong,nulls={},false,nil
    function client:request(options)
        captured[#captured+1]={url=options.url,referer=options.headers and options.headers.Referer,sensitive=options.sensitive}
        if wrong and options.url==root then
            -- Inject the other book's actual HTTP response at the transport boundary.
            local changed={};for key,value in pairs(options) do changed[key]=value end
            changed.url=other
            return request(self,changed)
        end
        local body,code,headers,status=request(self,options)
        if nulls and code==200 and options.url:sub(1,#root)==root then
            body=body:gsub('(window%.__INITIAL_STATE__%s*=%s*)(%{.-%})(%s*;%s*%(function)',function(prefix,encoded,suffix)
                local value=client:json_decode(encoded)
                local null=require('json').util.null
                if nulls=='sessions' then
                    value.reader.token,value.reader.pclts=null,null
                    value.reader.currentChapter.bookId=null
                    local progress=value.reader.progress.book or value.reader.progress;progress.bookId=null
                elseif nulls=='required' then value.reader.psvts=null
                else value.reader[nulls]=null end
                return prefix..client:json_encode(value)..suffix
            end,1)
        end
        return body,code,headers,status
    end
    local cache=assert(plugin.ui.document.file)
    local function digest()
        local file=assert(io.open(cache,'rb'));local value=file:read('*a');file:close();return Crypto.sha256_hex(value)
    end
    local original=digest()
    local book={book_id='900001',reader_url='https://example.invalid/stale',title='Keep synthetic title',
        cached_file=cache,chapter_offset=77,progress=83,pending_upload_position={percent=88},psvts='old',pclts='old',token='old'}
    local state=Content.ensure_reader_state(client,book)
    assert(state.book_id=='900001' and captured[1].url==root and captured[1].referer==root and captured[1].sensitive,
        'download retained foreign cached URL or diagnostics')
    assert(book.reader_url==root and book.title=='Keep synthetic title' and book.psvts=='mock-session' and book.token==nil,
        'valid context did not replace session fields or retained omitted token')
    book.reader_url=Protocol.reader_url('900001',2)..'?wvid=discard#discard'
    Content.ensure_reader_state(client,book)
    assert(captured[#captured].url==Protocol.reader_url('900001',2) and book.chapter_uid==2,'valid selected chapter lost or sharing data retained')
    Content.refresh_reader_state(client,book,{chapterUid=3})
    assert(captured[#captured].url==Protocol.reader_url('900001',3) and book.chapter_uid==3,'explicit chapter refresh selected wrong page')
    book.reader_url='https://example.invalid/stale';Content.fetch_catalog(client,book)
    assert(captured[#captured].referer==root and captured[#captured].sensitive,'catalog retained foreign referer')

    nulls='sessions';book.reader_url=root
    state=Content.ensure_reader_state(client,book)
    assert(state.psvts=='mock-session' and state.token==nil and state.pclts==nil
        and state.current_chapter.bookId==nil and state.progress.bookId==nil,'JSON null optional sessions/owners were not normalized')
    for _i,key in ipairs({'currentChapter','progress'}) do
        nulls=key;state=Content.ensure_reader_state(client,book)
        local record=key=='currentChapter' and state.current_chapter or state.progress
        assert(type(record)=='table' and next(record)==nil and state.psvts=='mock-session','JSON null optional position record was rejected')
    end
    nulls='required'
    local accepted,message=pcall(Content.ensure_reader_state,client,book)
    assert(not accepted and message==tr('The reading page could not be verified for this book. Refresh the book details and try again.')
        and book.psvts==nil and book.token==nil and book.pclts==nil,'JSON null required session was accepted or stale fields retained')
    nulls=nil

    wrong=true;book.reader_url=root
    local offset,progress=book.chapter_offset,book.progress
    local chapters=count('/web/book/chapter/e_0')+count('/web/book/chapter/e_1')+count('/web/book/chapter/e_3')
    local ok,err=pcall(Content.fetch_first_chapter,client,settings,book)
    assert(not ok and err==tr('The reading page could not be verified for this book. Refresh the book details and try again.'),
        'wrong-book HTTP response was accepted or exposed raw state')
    assert(book.psvts==nil and book.pclts==nil and book.token==nil and book.chapter_offset==offset and book.progress==progress
        and book.cached_file==cache and book.pending_upload_position.percent==88,'rejected context replaced local book or retained session')
    assert(count('/web/book/chapter/e_0')+count('/web/book/chapter/e_1')+count('/web/book/chapter/e_3')==chapters
        and digest()==original,'wrong-book response reached content download or replaced original EPUB')
    plugin:showInfo(err);UIManager:forceRePaint();require('device').screen:shot(home..'/../evidence/reader-context-rejected.png')
    UIManager:close(UIManager:getTopmostVisibleWidget());wrong=false

    control{match='/web/reader/',times=1,status=403,delay=0}
    book.psvts='old';book.pclts='old';book.token='old'
    ok,err=pcall(Content.ensure_reader_state,client,book)
    assert(not ok and err==tr('Could not load this book’s reading page. Check your connection and login, then try again.')
        and book.psvts==nil and book.pclts==nil and book.token==nil,'HTTP failure retained session or raw error')
    control{match='',times=0,delay=0}
    control{match='/web/book/chapterInfos',times=1,status=403,delay=0}
    local old_chapters=book.chapters
    ok,err=pcall(Content.fetch_catalog,client,book)
    assert(not ok and err==tr('Could not load this book’s chapter list. Check your connection and login, then try again.')
        and book.chapters==old_chapters,'catalog failure exposed raw response or erased cached chapters')
    control{match='',times=0,delay=0}
    local before=#captured
    ok=pcall(Content.ensure_reader_state,client,{book_id='900001',bookId='900002'})
    assert(not ok and #captured==before,'conflicting identity reached HTTP')
    client.request=request;flush()
    assert(count('/web/book/read')==writes,'Reader context guard wrote cloud reading state')
    local report={result='PASS',synthetic_only=true,stale_url_repaired=true,selected_chapter_preserved=true,
        sharing_fields_removed=true,catalog_referer_canonical=true,real_wrong_book_http_rejected=true,
        no_chapter_fetch_after_mismatch=true,cached_epub_unchanged=true,pending_upload_preserved=true,
        old_session_cleared=true,http_failure_clean=true,catalog_failure_preserves_cache=true,conflicting_alias_no_http=true,fixed_native_guidance=true,reading_writes=0}
    report.null_optional_sessions_clean=true;report.null_optional_positions_clean=true;report.null_required_session_rejected=true
    local file=assert(io.open(home..'/../evidence/reader-context.json','w'));file:write(client:json_encode(report));file:close()
    print('PASS: download same-book Reader context -> canonical root/chapter/catalog -> actual HTTP wrong-book rejection -> original EPUB/pending state preserved; clean session/403/ID conflict and native guidance; no reading writes')
end
