package.path = "./?.lua;" .. package.path

local calls = {}
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = function(_client, book)
            calls[#calls + 1] = "reader"
            book.reader_url = "https://reader/book"
        end,
        create_download_workspace = function()
            calls[#calls + 1] = "workspace"
            return { path = "/tmp/work", incoming_dir = "/tmp/work/in",
                asset_dir = "/tmp/work/images" }
        end,
        fetch_single_chapter_source = function(_client, settings)
            calls[#calls + 1] = "source"
            settings:update_auth({ wr_ticket = "renewed" })
            return "<p>body</p>"
        end,
        finalize_single_chapter_content = function()
            calls[#calls + 1] = "images"
            return "<p>final</p>", {}
        end,
        save_chapter_epub = function(_settings, book, _chapter, _body, _assets, css)
            assert(css == "\nstandard-footnote-css",
                "legacy popup preference must not override standard footnote CSS")
            calls[#calls + 1] = "epub"
            local path = "/tmp/book-chapter.epub"
            book.cache_dir = "/tmp/cache/book"
            book.annotation_documents = {
                [path] = { clean = true, chapters = { { chapterUid = "2" } } },
            }
            return path
        end,
        cleanup_download_workspace = function()
            calls[#calls + 1] = "cleanup"
        end,
    }
end
package.preload["weread.lib.footnotes"] = function()
    return {
        scan_chapter = function() return {} end,
        build_book_index = function() return {} end,
        transform_chapter = function(body) return body, { converted = 1 } end,
        validate = function() return true end,
        has_converted = function() return true end,
        FOOTNOTES_CSS = "standard-footnote-css",
    }
end

local flushes = 0
local values = {
    cache = { download_book_images = true, book_footnotes_in_popup = true },
    cookies = {}, wr_ticket = "old",
    wr_wrpa = "",
}
local settings = {
    get = function(_self, key, default)
        return values[key] == nil and default or values[key]
    end,
    set = function(_self, key, value) values[key] = value end,
    flush = function() flushes = flushes + 1 end,
}
settings.update_auth = function(self, credentials, options)
    if credentials.wr_ticket then self:set("wr_ticket", credentials.wr_ticket) end
    if not options or options.flush ~= false then self:flush() end
end

local progress = {}
local context = {
    emit = function(state) progress[#progress + 1] = state.stage end,
    checkCancelled = function() end,
    sleep = function() end,
}
local Worker = require("weread.lib.chapter_prefetch_worker")
local result = Worker.run(settings, {}, { book_id = "book" },
    { chapterUid = "2", title = "Two" }, context)

assert(result.path == "/tmp/book-chapter.epub")
assert(result.book_id == 'book' and result.chapter_uid == "2" and result.cache_dir == "/tmp/cache/book")
assert(result.annotation_document and result.annotation_document.clean)
assert(result.auth and result.auth.wr_ticket == "renewed")
assert(flushes == 0, "child worker must not flush parent LuaSettings")
assert(table.concat(calls, ",")
    == "reader,workspace,source,images,epub,cleanup")
assert(table.concat(progress, ",")
    == "reader,source,images,footnotes,epub")

local content=require("weread.lib.content")
local tries,sleeps=0,0
content.fetch_single_chapter_source=function() tries=tries+1;error("download_read/rate_limited",0) end
context.sleep=function() sleeps=sleeps+1 end
local ok,err=pcall(Worker.run,settings,{}, {book_id="book"},{chapterUid="2"},context)
assert(not ok and tostring(err):find("download_read/rate_limited",1,true) and tries==1 and sleeps==0,
    "prefetch retried a rate-limited chapter")
assert(calls[#calls]=="cleanup", "rate-limited prefetch did not clean its workspace")
tries,sleeps=0,0
content.fetch_single_chapter_source=function() tries=tries+1;error('book_reading/web_expired',0) end
ok,err=pcall(Worker.run,settings,{}, {book_id='book'},{chapterUid='2'},context)
assert(not ok and tostring(err):find('book_reading/web_expired',1,true) and tries==1 and sleeps==0,
    'prefetch retried a chapter after login expired')
assert(calls[#calls]=='cleanup','expired prefetch did not clean its workspace')
local request_count=0
content.ensure_reader_state=function(scoped,book)
    scoped:request{method='GET',url=require('weread.lib.protocol').reader_url(book.book_id)}
end
local expired_client={request=function() request_count=request_count+1;return nil,401,{} end}
ok,err=pcall(Worker.run,settings,expired_client,{book_id='book'},{chapterUid='2'},context)
assert(not ok and tostring(err):find('book_reading/web_expired',1,true) and request_count==1,
    'prefetch reader request did not classify a definite 401')
local scope_current=true
settings.get_auth_scope=function() return {vid='900000',epoch=1} end
settings.auth_scope_matches=function() return scope_current end
content.ensure_reader_state=function() end
content.fetch_single_chapter_source=function() return '<p>synthetic</p>' end
local saved=false
content.save_chapter_epub=function(_settings,_book,_chapter,_body,_assets,_css,_identity,_source,_output,guard)
    scope_current=false
    guard();saved=true
    return '/tmp/never-published.epub'
end
ok,err=pcall(Worker.run,settings,{}, {book_id='book'},{chapterUid='2'},context)
assert(not ok and tostring(err):find('chapter_prefetch/session_changed',1,true) and not saved and calls[#calls]=='cleanup',
    'changed account was allowed to publish a prefetched chapter')

-- Native resources are used only with the parent's captured grant, while the
-- original Web position source continues through the normal EPUB save path.
scope_current=true
local native_current,native_calls,native_mode=true,0,'success'
local selected={fingerprint='grant-1'}
package.loaded['weread.lib.native_read_access']={
    capture=function() return selected end,
    matches=function(_,value) return value==selected and native_current end,
}
local original={format='web_xhtml'}
package.loaded['weread.lib.native_chapter_candidate']={fetch=function(_,_,_,_,web,proof,workspace,expected)
    native_calls=native_calls+1
    assert(web=='web-body' and proof==original and workspace and expected=='grant-1')
    if native_mode=='fallback' then return nil end
    if native_mode=='expired' then error('native_candidate/auth_expired',0) end
    if native_mode=='switched' then native_current=false end
    return {xhtml='native-body',css='native-css',assets={{href='images/verified.png',path='/tmp/work/images/verified.png'}}}
end}
content.fetch_single_chapter_source=function() return 'web-body',original end
local saved_mode
content.finalize_single_chapter_content=function(_,_,_,_,xhtml)
    assert(xhtml=='web-body');return 'web-final',{}
end
content.save_chapter_epub=function(_,_,_,body,assets,css,_,proof,_,guard)
    guard();assert(proof==original)
    if native_mode=='fallback' then
        assert(body=='web-final' and #assets==0 and css=='\nstandard-footnote-css')
    else
        assert(body=='native-body' and #assets==1 and css=='native-css\nstandard-footnote-css')
    end
    saved_mode=native_mode;return '/tmp/book-chapter.epub'
end
local function native_run()
    return Worker.run(settings,{}, {book_id='book'}, {chapterUid='2'},context,nil,nil,'grant-1')
end
native_run();assert(saved_mode=='success' and native_calls==1)
native_mode='fallback';native_run();assert(saved_mode=='fallback' and native_calls==2)
native_mode='expired';local before=native_calls
ok,err=pcall(native_run)
assert(not ok and tostring(err):find('native_candidate/auth_expired',1,true)
    and native_calls==before+1 and saved_mode=='fallback' and calls[#calls]=='cleanup')
native_mode='switched';native_current=true
ok,err=pcall(native_run)
assert(not ok and tostring(err):find('chapter_prefetch/session_changed',1,true)
    and saved_mode=='fallback' and calls[#calls]=='cleanup')
native_current=true;selected.fingerprint='different';before=native_calls
ok,err=pcall(native_run)
assert(not ok and tostring(err):find('chapter_prefetch/session_changed',1,true) and native_calls==before)

print("chapter_prefetch_worker_spec: isolated settings and complete pipeline passed")
