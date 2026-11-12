-- Distinct real HTTP bodies, native SQLite/settings, filesystem and CRE.
return function(plugin,count,flush,home,pump,assert_snapshot)
    local Content=require('weread.lib.content')
    local Identity=require('weread.lib.mp_cache_identity')
    local Output=require('weread.lib.notes_export_file')
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local lfs=require('libs/libkoreader-lfs')
    local tr=require('weread.lib.i18n').tr
    local settings,client=plugin.settings,plugin.client
    local old_cache=settings:get('cache',{})
    local cache={};for key,value in pairs(old_cache) do cache[key]=value end
    cache.download_mp_images=false;settings:set('cache',cache);settings:flush()
    local book={book_id='MP_WXS_900098',title='合成缓存隔离',cache_dir=settings.data_dir..'/moved-mp-cache',
        progress=.3,pending_upload_position={chapter_uid=1,chapter_offset=4}}
    local a={reviewId='cache-fixture-a/b',title='同名文章'}
    local b={reviewId='cache-fixture-a_b',title='同名文章'}
    local c={reviewId='cache-fixture-c',title='旧缓存同名'}
    local d={reviewId='cache-fixture-d',title='旧缓存同名'}
    local e={reviewId='legacy-unique',title='旧缓存唯一'}
    book.mp_articles={a,b,c,d,e}
    local books=settings:get('books',{});books[book.book_id]=book;settings:set('books',books);settings:flush()
    local saved=client:json_encode(settings:get('books',{})[book.book_id])
    local reading_writes=count('/web/book/read')
    local reads=count('/web/mp/content')
    assert(not Content.mp_article_cached_path(settings,book,a),'new article guessed a missing legacy cache')
    local function read(path)
        local file=assert(io.open(path,'rb'));local data=file:read('*a');file:close();return data
    end
    local function write(path,data)
        assert(require('util').makePath(path:match('^(.*)/[^/]+$')) or lfs.attributes(path:match('^(.*)/[^/]+$'),'mode')=='directory')
        local file=assert(io.open(path,'wb'));file:write(data);file:close()
    end
    local old_open=plugin.openFile;local opened
    plugin.openFile=function(_self,path) opened=path end
    local function download(article)
        opened=nil;plugin:downloadMPArticleAndRead(book,article);flush();pump(function() return not plugin.mp_download_job end)
        assert(opened and not plugin.busy_message,'native MP download did not finish')
        return opened
    end
    local path_a=download(a);local data_a=read(path_a)
    local path_b=download(b);local data_b=read(path_b)
    assert(path_a~=path_b and data_a:find('合成公众号正文甲',1,true) and data_b:find('合成公众号正文乙',1,true),'same-title articles overwrote or read one another')
    assert(read(path_a)==data_a,'second article replaced first body')
    assert(Identity.valid(book.cache_dir,Identity.key(book,a)) and Identity.valid(book.cache_dir,Identity.key(book,b)),'cache identity header not valid')
    a.title='文章已更名'
    assert(Content.mp_article_cached_path(settings,book,a)==path_a,'title change orphaned cache')
    local parent_a=path_a:match('^(.*)/[^/]+$');local parent_b=path_b:match('^(.*)/[^/]+$')
    write(parent_a..'/.weread-mp-cache-fixture-a_b-assets/img-0001.png','first image')
    write(parent_b..'/.weread-mp-cache-fixture-a_b-assets/img-0001.png','second image')
    assert(read(parent_a..'/.weread-mp-cache-fixture-a_b-assets/img-0001.png')=='first image','sanitized image namespace collided')
    local document=assert(require('document/documentregistry'):openDocument(path_b))
    assert(document:loadDocument());document:render()
    local visible=document:getTextFromXPointer('/html/body') or document:getTextFromXPointer('/body')
    assert(type(visible)=='string' and visible:find('合成公众号正文乙',1,true),'native HTML cache did not render selected body');document:close()
    plugin:showMPArticleList(book,{a,b})
    local menu=assert(plugin._mp_article_list_view)
    menu:onMenuSelect(menu.item_table[1]);assert(opened==path_a,'renamed article menu opened wrong file')
    plugin:showMPArticleExportList(book,{a,b})
    local exports=assert(plugin._mp_export_menu)
    assert(#exports.item_table==2 and exports.item_table[1].select_enabled~=false and exports.item_table[2].select_enabled~=false,'distinct cache identities were disabled as same-title ambiguity')
    plugin:closeWeReadUI()
    local legacy_c=Content.mp_article_legacy_path(settings,book,c)
    local old_html='<html><body><p>旧正文保留</p></body></html>'
    write(legacy_c,old_html)
    local cached,reason=Content.mp_article_cached_path(settings,book,c)
    assert(cached==nil and reason=='ambiguous_legacy','ambiguous old title was guessed')
    plugin:showMPArticleList(book,{c,d})
    menu=assert(plugin._mp_article_list_view)
    assert(menu.item_table[1].mandatory==tr('Legacy cache needs refresh'),'legacy ambiguity not visible')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-cache-legacy-ambiguous.png')
    menu:onMenuSelect(menu.item_table[1]);flush();pump(function() return not plugin.mp_download_job end)
    assert(opened~=legacy_c and opened==Content.mp_article_path(settings,book,c),'ambiguous old row did not re-download selected identity')
    assert(read(legacy_c)==old_html,'redownload removed or rewrote old ambiguous file')
    local legacy_e=Content.mp_article_legacy_path(settings,book,e);write(legacy_e,old_html)
    cached,reason=Content.mp_article_cached_path(settings,book,e)
    assert(cached==legacy_e and reason=='legacy','unambiguous old HTML lost offline compatibility')
    assert(not lfs.attributes(Content.mp_article_path(settings,book,e)),'old cache silently promoted to identity path')
    plugin:showMPArticleList(book,{a,b,e})
    menu=assert(plugin._mp_article_list_view);assert(menu.item_table[3].mandatory==tr('Legacy cache'),'legacy provenance not labelled')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-cache-distinct.png')
    local factory=Output.create
    Output.create=function() return nil end
    local ok=pcall(Content.save_mp_article_html,settings,book,a,'<p>must not replace old body</p>')
    Output.create=factory
    assert(not ok and read(path_a)==data_a,'failed atomic save changed earlier HTML')
    write(path_a,(data_a:gsub(Identity.key(book,a),Identity.key(book,b),1)))
    assert(not Content.mp_article_cached_path(settings,book,a),'wrong identity header was accepted')
    download(a);assert(Identity.valid(book.cache_dir,Identity.key(book,a)),'redownload did not replace corrupted scoped cache')
    local target=settings.data_dir..'/mp-cache-external-keep.html';write(target,'keep outside')
    local link_article={reviewId='symlink',title='Symlink'}
    local link_path=assert(Identity.prepare(book.cache_dir,Identity.key(book,link_article)))
    assert(lfs.link(target,link_path,true))
    assert(not Content.mp_article_cached_path(settings,book,link_article),'cache symlink followed')
    ok=pcall(Content.save_mp_article_html,settings,book,link_article,'<p>overwrite</p>')
    assert(not ok and read(target)=='keep outside','cache writer followed symlink');os.remove(link_path)
    local unsafe={book_id=book.book_id,cache_dir=settings.data_dir..'/mp-cache-parent-link'}
    local outside=settings.data_dir..'/mp-cache-outside-directory'
    assert(require('util').makePath(unsafe.cache_dir) or lfs.attributes(unsafe.cache_dir,'mode')=='directory')
    assert(require('util').makePath(outside) or lfs.attributes(outside,'mode')=='directory')
    assert(lfs.link(outside,unsafe.cache_dir..'/mp-articles',true))
    ok=pcall(Content.save_mp_article_html,settings,unsafe,a,'<p>must not escape parent</p>')
    assert(not ok and not lfs.attributes(outside..'/'..Identity.key(unsafe,a)),'managed parent symlink was followed')
    os.remove(unsafe.cache_dir..'/mp-articles')
    plugin.openFile=old_open;plugin:closeWeReadUI()
    settings:set('cache',old_cache);settings:flush()
    local order_only=assert_snapshot(saved,settings:get('books',{})[book.book_id],'cache operations changed local progress/intent or record')
    assert(count('/web/book/read')==reading_writes and count('/web/mp/content')==reads+4,'cache workflow submitted reading data or unexpected reads')
    local report={result='PASS',synthetic_only=true,record_json_order_only_changed=order_only,http_reads=4,reading_data_writes=0,distinct_same_title_bodies=true,
        sanitized_id_collision_separated=true,title_rename_keeps_path=true,identity_header_checked=true,
        image_directories_isolated=true,native_html_render=true,native_menu_opens_selected_identity=true,
        export_choices_remain_distinct=true,legacy_ambiguity_visible=true,legacy_ambiguity_not_read=true,
        selected_identity_redownloaded=true,legacy_file_preserved=true,legacy_unique_readonly=true,
        no_legacy_promotion=true,legacy_label_visible=true,atomic_save_failure_preserved_body=true,
        wrong_identity_rejected=true,cache_symlink_not_followed=true,local_progress_pending_unchanged=true}
    report.managed_parent_symlink_rejected=true
    write(home..'/../evidence/mp-cache-identity.json',client:json_encode(report))
    print('PASS: native HTTP MP cache -> same-title distinct identities, rename/CRE/menus/export; legacy ambiguity/redownload/read-only preservation, failed atomic save and symlink guard')
end
