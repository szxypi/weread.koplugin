-- Actual source text is never printed or captured in screenshots. Only counters
-- leave the tmpfs-profile runner, which has no account credentials.
return function(samples,result)
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-notes%-[%w_]+/profile$'))
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home .. '/settings.reader.lua')
    for key,value in pairs({language='zh_CN',footnote_link_in_popup=true,tap_to_follow_links=true,copt_font_size=24,
        color_rendering=false,extra_plugin_paths={home .. '/plugins'}}) do G_reader_settings:saveSetting(key,value) end
    require('gettext').changeLang('zh_CN');require('ui/bidi').setup('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    local UI=require('ui/uimanager')
    local Screen=Device.screen
    local function deny() error('network_forbidden') end
    require('socket.http').request=deny;require('ssl.https').request=deny
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1,'plugin_missing')
    local Reader=require('apps/reader/readerui');local Registry=require('document/documentregistry')
    local Content=require('weread.lib.content');local Identity=require('weread.lib.book_file_identity')
    local Geom=require('ui/geometry')
    result._native_private={}
    local todo,books={},{}
    local settings=require('weread.lib.settings'):new()
    for index,sample in ipairs(samples) do
        if #sample.expected>0 then
            local book={bookId=tostring(990191+index),title='Private note sample',bookVersion=7,cache_dir=home .. '/notes/' .. index}
            local chapter={chapterUid=sample.chapter.chapterUid,chapterIdx=sample.chapter.chapterIdx,title='Sample ' .. index}
            local path=Content.save_chapter_epub({},book,chapter,sample.html,{},require('weread.lib.footnotes').FOOTNOTES_CSS,Identity.capture(book))
            book.chapters={chapter};book.cached_chapters={[tostring(chapter.chapterUid)]=path};books[book.bookId]=book
            assert(Content.save_catalog_cache({json_encode=function(_self,value) return require('json').encode(value) end},settings,book,{chapter}))
            todo[#todo+1]={path=path,sample_index=index,book_id=book.bookId,uid=tostring(chapter.chapterUid),expected=sample.expected}
        end
    end
    if #todo==0 then return end
    settings:set('books',books);settings:set('sync',{pull_on_open=false,upload_on_close=false})
    local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.show_annotations=false;settings:set('cache',cache);settings:flush()
    local reader,popup,origin,current,ordinal
    local steps={}
    for _i,item in ipairs(todo) do
        steps[#steps+1]=function()
            current=item;ordinal=1
            reader=Reader:new{dimen=Screen:getSize(),document=Registry:openDocument(item.path)};UI:show(reader)
            assert(reader.weread._current_weread_book_id==current.book_id,'plugin_book_missing')
            assert(reader.weread._rich_footnote_guard,'guard_missing')
            result.native_plugin_checks=result.native_plugin_checks+1
            result.native_opened_chapters=result.native_opened_chapters+1
        end
        steps[#steps+1]=function()
            local number=ordinal
            local ref='#_doc_fragment_0_ wrfnref-' .. current.uid .. '-' .. number
            assert(reader.document:isXPointerInDocument(ref),'reference_missing')
            reader.rolling:onGotoXPointer(ref);origin=reader.rolling.xpointer
            local gesture,selected
            for _j,link in ipairs(reader.document:getPageLinks()) do
                if link.segments and #link.segments>0 then
                    local rect=link.segments[1]
                    local candidate={pos=Geom:new{x=(rect.x0+rect.x1)/2,y=(rect.y0+rect.y1)/2}}
                    local actual=reader.link:getLinkFromGes(candidate)
                    if actual and actual.xpointer=='#_doc_fragment_0_ wrfn-' .. current.uid .. '-' .. number then gesture,selected=candidate,actual;break end
                end
            end
            assert(gesture,'reference_not_visible')
            local return_point=selected.from_xpointer or origin
            local source_page=reader.document:getCurrentPage()
            reader.link:onTap(nil,gesture)
            popup=nil
            for widget in UI:topdown_widgets_iter() do if widget.html and widget.htmlwidget then popup=widget;break end end
            assert(popup,'popup_missing')
            result._native_private[#result._native_private+1]={sample_index=current.sample_index,note_index=number,html=popup.html}
            assert(reader.rolling.xpointer==origin,'popup_moved_reader')
            result.native_popup_checks=result.native_popup_checks+1
            popup:onClose();popup=nil
            local enabled=reader.link:getFootnoteSettingsMenuTable()[1];if enabled.checked_func() then enabled.callback() end
            reader.link:onTap(nil,gesture)
            assert(reader.rolling.xpointer=='#_doc_fragment_0_ wrfn-' .. current.uid .. '-' .. number,'note_jump_missing')
            result.native_jump_checks=result.native_jump_checks+1
            assert(reader.link:onGoBackLink(true),'native_back_missing')
            assert(reader.rolling.xpointer==return_point and reader.document:getCurrentPage()==source_page,'native_back_mismatch')
            result.native_back_checks=result.native_back_checks+1
            if not enabled.checked_func() then enabled.callback() end
            ordinal=ordinal+1
            if ordinal<=#current.expected then return false end
        end
        steps[#steps+1]=function()
            reader:onClose(false);reader:showFileManager(current.path);reader=nil
        end
    end
    local index,failure=1,nil
    local function advance()
        if not steps[index] then UI:quit();return end
        local ok,value=pcall(steps[index])
        if not ok then
            local label=tostring(value):match(':%s*([a-z_]+)$')
            local codes={reference_missing=1,reference_not_visible=2,gesture_missing=3,popup_missing=4,popup_text_mismatch=5,
                popup_moved_reader=6,note_jump_missing=7,native_back_missing=8,native_back_mismatch=9,plugin_book_missing=10,guard_missing=11}
            result.native_error_code=codes[label] or 98;result.native_failure_stage=index
            failure=true;UI:quit();return
        end
        if value~=false then index=index+1 end
        UI:scheduleIn(.2,advance)
    end
    advance();UI:run()
    if not failure and index<=#steps then result.native_error_code=97;result.native_failure_stage=index end
end
