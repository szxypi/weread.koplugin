package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local encoded_values = {}
local encoded_index = 0
local sync_events,fail_sync={},nil
package.preload['ffi/util']=function() return {
    fsyncOpenedFile=function() sync_events[#sync_events+1]='file';return fail_sync~='file' end,
    fsyncDirectory=function(dir) sync_events[#sync_events+1]=dir;return fail_sync~='directory' end,
} end
local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = deepcopy(item) end
    return copy
end

package.preload["json"] = function()
    return {
        encode = function(value)
            encoded_index = encoded_index + 1
            local token = "json-fixture-" .. tostring(encoded_index)
            encoded_values[token] = deepcopy(value)
            return token
        end,
        decode = function(token)
            assert(encoded_values[token], "unknown JSON fixture token")
            return deepcopy(encoded_values[token])
        end,
    }
end

local BookStore = require("weread.lib.book_store")
local root = os.tmpname() .. "-weread-book-store"
os.remove(root)
local settings = { cache_dir = root }

local ok, index = BookStore.save(settings, "book/42", {
    book_id = "book/42",
    title = "Fixture book",
    author = "Fixture author",
    progress = 37,
    chapter_uid = 9,
    pending_upload_account = "synthetic-account-key",
    unindexed_resume = {chapter_uid='9'},
    source_dispatch = { schema = 1, id = "synthetic-receipt", account = "synthetic-account-key" },
    mp_articles = { { title = "Fixture article" } },
    chapters = { { chapterUid = 9 } },
})
expect(ok == true, "split book save failed")
expect(index.cache_dir == root .. "/book_42",
    "book id was not sanitized for the cache directory")
expect(BookStore.is_minimal_index({ ["book/42"] = index }),
    "saved index was not minimal")
expect(not BookStore.is_minimal_index({
    ["book/42"] = { cache_dir = index.cache_dir, title = "legacy" },
}), "legacy inline metadata was accepted as a minimal index")

local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

expect(exists(index.cache_dir .. "/metadata.json"),
    "metadata file was not written")
expect(exists(index.cache_dir .. "/reading_state.json"),
    "reading-state file was not written")
expect(exists(index.cache_dir .. "/articles.json"),
    "article file was not written")

local routed, routing_index = BookStore.save(settings, "routing", {
    book_id = "routing", cache_dir = root .. "/routing", cached_file = root .. "/external/chapter.epub",
})
expect(routed, "could not save path lookup fixture")
local original_open, lookup_reads = io.open, {}
rawset(io, "open", function(path, mode)
    lookup_reads[#lookup_reads + 1] = path
    return original_open(path, mode)
end)
local route = { routing = routing_index }
local managed, managed_dir, managed_evidence = BookStore.find_file(settings, route, routing_index.cache_dir .. "/chapter.epub")
local external, external_dir, external_evidence = BookStore.find_file(settings, route, root .. "/external/chapter.epub")
local neighbor = BookStore.find_file(settings, route, routing_index.cache_dir .. "-other/chapter.epub")
local legacy, legacy_dir = BookStore.find_file(settings, { legacy = { cache_dir = root .. "/legacy",
    cached_file = root .. "/legacy-copy.epub" } }, root .. "/legacy-copy.epub")
rawset(io, "open", original_open)
expect(managed == "routing" and managed_dir == routing_index.cache_dir .. "/" and managed_evidence == "directory"
    and external == managed and external_dir == managed_dir and external_evidence == "recorded"
    and not neighbor and legacy == "legacy" and legacy_dir == root .. "/legacy/",
    "book path lookup lost a managed or legacy exact path, or matched a neighboring directory")
expect(#lookup_reads == 3 and lookup_reads[1] == routing_index.cache_dir .. "/metadata.json"
    and lookup_reads[2] == lookup_reads[1] and lookup_reads[3] == root .. "/legacy/metadata.json",
    "path lookup read unrelated records or checked metadata for a known directory")
expect(not BookStore.find_file(settings, { routing = { cache_dir = routing_index.cache_dir,
    cached_file = root .. "/stale-inline.epub" } }, root .. "/stale-inline.epub"),
    "current metadata did not supersede an obsolete inline cached path")

local overlap = {
    { cache_dir = root },
    { cache_dir = root .. '/external' },
    { cache_dir = root .. '/external/book' },
}
rawset(io, 'open', function() error('indexed directory detection should not read metadata') end)
expect(BookStore.find_file(settings, overlap, root .. '/external/book/file.epub') == 3,
    'broader legacy record claimed a more specific directory')
expect(BookStore.find_file({ cache_dir = root .. '/managed' }, overlap, root .. '/external/book/file.epub') == 3,
    'earlier nested index claimed the file')
rawset(io, 'open', original_open)
expect(not BookStore.find_file(settings, overlap, root .. '/ordinary.epub'), 'cache root claimed an unrelated file')
local duplicate = { { cache_dir = root .. '/shared' }, { cache_dir = root .. '/shared/' } }
local shared_id, _, shared_evidence = BookStore.find_file(settings, duplicate, root .. '/shared/book.epub')
expect(not shared_id and shared_evidence == 'ambiguous', 'duplicate directory took ownership of an ambiguous file')
local exact_path = root .. '/legacy-chapter.epub'
local legacy_chapter = { { cache_dir = root, cached_chapters = { ['7'] = exact_path } } }
expect(BookStore.find_file(settings, legacy_chapter, exact_path) == 1, 'recorded legacy chapter became unrecognizable')
legacy_chapter[2] = { cache_dir = root .. '/unrelated', cached_full_book = exact_path }
local exact_id, _, exact_evidence = BookStore.find_file(settings, legacy_chapter, exact_path)
expect(not exact_id and exact_evidence == 'ambiguous', 'a file explicitly claimed by two books was assigned arbitrarily')

expect(not BookStore.has_legacy_catalog(settings, "routing", routing_index), "modern metadata was marked legacy")
local legacy_metadata_path = routing_index.cache_dir .. "/metadata.json"
local legacy_metadata = assert(io.open(legacy_metadata_path, "wb"))
assert(legacy_metadata:write(require("json").encode({book_id="routing",chapters={{chapterUid=7}}})))
assert(legacy_metadata:close())
local catalog_reads = 0
rawset(io, "open", function(path, mode)
    assert(path == legacy_metadata_path, "migration detection read a non-metadata file")
    catalog_reads = catalog_reads + 1
    return original_open(path, mode)
end)
local needs_migration = BookStore.has_legacy_catalog(settings, "routing", routing_index)
rawset(io, "open", original_open)
expect(needs_migration and catalog_reads == 1, "legacy catalog behind a minimal index was missed")

local loaded = BookStore.load(settings, "book/42", index)
local metadata_only = BookStore.without_reading_state(loaded)
expect(metadata_only.title == loaded.title and metadata_only.cache_dir == loaded.cache_dir,
    "metadata filtering lost ordinary fields or cache paths")
expect(metadata_only.progress == nil and metadata_only.pending_upload_account == nil
    and metadata_only.source_dispatch == nil and metadata_only.unindexed_resume==nil
    and loaded.progress == 37 and loaded.source_dispatch.id == "synthetic-receipt",
    "metadata filtering retained reading state or mutated its caller")
expect(BookStore.is_reading_field("pending_upload_position") and BookStore.is_reading_field("source_dispatch")
    and BookStore.is_reading_field('native_location_claims')
    and BookStore.is_reading_field('unindexed_resume')
    and BookStore.is_reading_field('cb_cloud_view_resume')
    and not BookStore.is_reading_field("title") and not BookStore.is_reading_field("cache_dir"),
    "metadata/checkpoint ownership is inconsistent")
expect(loaded.title == "Fixture book" and loaded.author == "Fixture author",
    "metadata did not round-trip")
expect(loaded.progress == 37 and loaded.chapter_uid == 9,
    "reading state did not round-trip")
expect(loaded.pending_upload_account == "synthetic-account-key", "pending upload account did not round-trip")
local state_file = assert(io.open(index.cache_dir .. "/reading_state.json", "rb"))
local state = require("json").decode(state_file:read("*a"))
state_file:close()
expect(state.pending_upload_account == "synthetic-account-key", "pending owner escaped the reading-state file")
expect(state.source_dispatch.id == "synthetic-receipt" and loaded.source_dispatch.id == "synthetic-receipt",
    "dispatch journal did not survive per-book reading-state storage")
expect(state.unindexed_resume.chapter_uid=='9' and loaded.unindexed_resume.chapter_uid=='9',
    'local-only resume hint was not stored with reading state')
expect(loaded.mp_articles[1].title == "Fixture article",
    "article data did not round-trip")
expect(loaded.chapters == nil,
    "large chapter catalog should not be stored in the book record")
expect(loaded.cache_dir == index.cache_dir,
    "resolved cache directory did not round-trip")
local metadata_file=assert(io.open(index.cache_dir..'/metadata.json','rb'))
local metadata_bytes=metadata_file:read('*a');metadata_file:close()
expect(BookStore.patch_reading(settings,'book/42',index,{progress=38,source_dispatch=false}),
    'bounded reading-state patch failed')
local patched=BookStore.load(settings,'book/42',index)
expect(patched.progress==38 and not patched.source_dispatch and patched.chapter_uid==9
    and patched.pending_upload_account=='synthetic-account-key','patch overwrote unrelated state')
metadata_file=assert(io.open(index.cache_dir..'/metadata.json','rb'))
expect(metadata_file:read('*a')==metadata_bytes,'late reading patch rewrote metadata');metadata_file:close()
expect(not BookStore.patch_reading(settings,'book/42',index,{title='late stale title'}),'reading patch changed non-state data')
expect(BookStore.patch_reading(settings,'book/42',index,{home_recent_at=100,home_recent_account='',last_local_account='owner'}),
    'account-scoped home and local-position checkpoint failed')
patched=BookStore.load(settings,'book/42',index)
expect(patched.home_recent_at==100 and patched.home_recent_account=='' and patched.last_local_account=='owner'
    and patched.pending_upload_account=='synthetic-account-key','recent reading changed unrelated pending ownership')
expect(BookStore.patch_reading(settings,'book/42',index,{native_home_resume={at=100,entry={book_id='42'}}}),
    'native home pointer patch failed')
expect(BookStore.load(settings,'book/42',index).native_home_resume.entry.book_id=='42',
    'native home pointer did not round-trip with reading state')
expect(BookStore.patch_reading(settings,'book/42',index,{native_home_resume=false})
    and not BookStore.load(settings,'book/42',index).native_home_resume,'ordinary reading did not clear native pointer')
metadata_file=assert(io.open(index.cache_dir..'/metadata.json','rb'))
expect(metadata_file:read('*a')==metadata_bytes,'recent event rewrote metadata');metadata_file:close()

-- An error delayed until fclose must not replace the committed checkpoint.
local state_path=index.cache_dir..'/reading_state.json'
local function bytes(path)
    local file=assert(io.open(path,'rb'));local raw=file:read('*a');assert(file:close());return raw
end
local before_close_failure=bytes(state_path)
local real_open=io.open
local failed_path=state_path
local function close_failure_open(path,mode)
    local file,err=real_open(path,mode)
    if path~=failed_path..'.tmp' or mode~='wb' or not file then return file,err end
    return {write=function(_self,raw) return file:write(raw) end,
        flush=function() return file:flush() end,
        close=function() assert(file:close());return nil,'synthetic delayed I/O failure' end}
end
rawset(io,'open',close_failure_open)
local saved,save_error=BookStore.patch_reading(settings,'book/42',index,{progress=99,source_dispatch={id='new-dispatch'}})
rawset(io,'open',real_open)
expect(saved==false and save_error=='synthetic delayed I/O failure','close failure was reported as a successful save')
expect(bytes(state_path)==before_close_failure and not exists(state_path..'.tmp'),
    'close failure replaced the old checkpoint or retained incomplete temporary state')
expect(BookStore.load(settings,'book/42',index).progress==38,'fresh load accepted the failed checkpoint')

local wire={book_id='900001',chapter_uid='2',chapter_idx=1,chapter_offset=5,percent=37}
local created,journal_index=BookStore.save(settings,'900001',{book_id='900001',progress=37,pending_upload_position=wire})
expect(created,'could not prepare dispatch persistence fixture')
failed_path=journal_index.cache_dir..'/reading_state.json'
local journal_before=bytes(failed_path)
local journal_settings={
    get=function(_self,key,default) return key=='account' and {user_vid='900000'} or default end,
    get_book=function() return BookStore.load(settings,'900001',journal_index) end,
    patch_reading_state=function(_self,id,patch) return BookStore.patch_reading(settings,id,journal_index,patch) end,
}
local journal=require('weread.lib.source_dispatch'):new{settings=journal_settings,nonce=function() return string.rep('a',32) end}
local source={book_id='900001',chapter_uid='2',chapter_offset=5,basis='filtered_xhtml_utf16',upload_verified=false,
    file_id=string.rep('b',64),raw_sha256=string.rep('c',64),book_version=1,render_path='OEBPS/text/chapter.xhtml'}
rawset(io,'open',close_failure_open)
local receipt=journal:begin('900001',wire,source,'position')
rawset(io,'open',real_open)
expect(not receipt,'unconfirmed fclose granted permission to send an upload')
expect(bytes(failed_path)==journal_before and not exists(failed_path..'.tmp') and not journal:pending('900001'),
    'failed dispatch save changed committed state')

sync_events={};fail_sync='file'
receipt=journal:begin('900001',wire,source,'position')
expect(not receipt and not journal:pending('900001') and bytes(failed_path)==journal_before
    and not exists(failed_path..'.tmp') and sync_events[1]=='file',
    'failed file synchronization permitted dispatch or replaced the old record')
sync_events={};fail_sync='directory'
receipt=journal:begin('900001',wire,source,'position')
expect(not receipt and journal:pending('900001') and sync_events[1]=='file' and #sync_events==2,
    'failed directory synchronization permitted dispatch or lost the published marker')
fail_sync=nil;sync_events={}
expect(journal:resolve('900001') and not journal:pending('900001') and #sync_events>=2,
    'explicit resolution did not synchronize the cleared marker')
sync_events={}
receipt=assert(journal:begin('900001',wire,source,'position'))
expect(sync_events[1]=='file' and #sync_events>=2 and journal:owns(receipt),
    'dispatch receipt preceded file and directory synchronization')
sync_events={}
expect(BookStore.patch_reading(settings,'900001',journal_index,{progress=41}) and journal:owns(receipt)
    and sync_events[1]=='file' and #sync_events>=2,
    'ordinary patch replaced a pending dispatch without synchronization')
sync_events={}
local pending_book=BookStore.load(settings,'900001',journal_index)
expect(BookStore.save(settings,'900001',pending_book) and journal:owns(receipt)
    and sync_events[1]=='file' and #sync_events>=2,
    'full book save replaced a pending dispatch without synchronization')
expect(journal:finish(receipt,{acknowledged=true,position_confirmed=true}) and not journal:pending('900001'),
    'confirmed synchronized dispatch did not finish')
os.remove(journal_index.cache_dir..'/reading_state.json')
os.remove(journal_index.cache_dir..'/metadata.json');os.remove(journal_index.cache_dir)

-- Linux CI also exercises a real kernel write error, delayed by stdio until
-- close. Restore the process limits and signal handler before any assertions.
local ffi=require('ffi')
if ffi.os=='Linux' and ffi.abi('64bit') then
    ffi.cdef[[
        struct weread_io_limits { uint64_t current; uint64_t maximum; };
        int getrlimit(int resource, void *limits);
        int setrlimit(int resource, const void *limits);
        void *signal(int signum, void *handler);
    ]]
    local previous=ffi.new('struct weread_io_limits')
    expect(ffi.C.getrlimit(1,previous)==0,'could not observe file-size limit')
    local limited=ffi.new('struct weread_io_limits',{8,previous.maximum})
    local handler=ffi.C.signal(25,ffi.cast('void *',1))
    local changed=ffi.C.setrlimit(1,limited)==0
    local called,result=pcall(BookStore.patch_reading,settings,'book/42',index,{progress=99})
    local restored=ffi.C.setrlimit(1,previous)==0
    ffi.C.signal(25,handler)
    expect(changed and restored and called and result==false,'kernel close failure was accepted as a save')
    expect(bytes(state_path)==before_close_failure and not exists(state_path..'.tmp'),
        'kernel I/O failure destroyed the committed checkpoint')
end

local corrupt=assert(io.open(index.cache_dir..'/reading_state.json','wb'));corrupt:write('corrupt fixture');corrupt:close()
expect(not BookStore.patch_reading(settings,'book/42',index,{progress=39}),'malformed stored state was silently replaced')

ok, index = BookStore.save(settings, "book/42", {
    book_id = "book/42",
    title = "Metadata only",
    cache_dir = index.cache_dir,
})
expect(ok == true, "metadata-only update failed")
expect(not exists(index.cache_dir .. "/reading_state.json")
    and not exists(index.cache_dir .. "/articles.json"),
    "stale split files were not removed")
loaded = BookStore.load(settings, "book/42", index)
expect(loaded.title == "Metadata only"
    and loaded.progress == nil and loaded.mp_articles == nil,
    "removed split state reappeared after reload")

-- The same cached book may be read by two accounts. A's legacy state must
-- stay intact while B saves, clears, and reloads an independent checkpoint.
local owner_a,owner_b=string.rep('a',20),string.rep('b',20)
ok,index=BookStore.save(settings,'book/42',{book_id='book/42',cache_dir=index.cache_dir,
    title='Legacy shared book',recent_read_account=owner_a,_library_account_key=owner_a,
    last_local_position={percent=31},pending_upload_position={percent=32},pending_upload_reason='old',
    source_dispatch={account=owner_a,id='old-uncertainty'}})
expect(ok,'legacy account fixture could not be saved')
local old_state=bytes(index.cache_dir..'/reading_state.json')
local active=owner_b
local scoped={cache_dir=root,account_state_scope=function() return active end}
local foreign=BookStore.load(scoped,'book/42',index)
expect(not foreign.pending_upload_position and not foreign.last_local_position and not foreign.source_dispatch,
    'another account inherited legacy checkpoints')
expect(BookStore.patch_reading(scoped,'book/42',index,{pending_upload_position={percent=61},
    pending_upload_account=owner_b,last_local_position={percent=62},last_local_account=owner_b}),
    'second account checkpoint was not saved')
local own_b=BookStore.load(scoped,'book/42',index)
expect(own_b.pending_upload_position.percent==61 and own_b.last_local_position.percent==62,
    'second account checkpoint did not reload')
own_b._library_account_key=owner_b;own_b.recent_read_account=nil
expect(BookStore.save(scoped,'book/42',own_b),'second account metadata update failed')
local scoped_path=index.cache_dir..'/.weread-accounts/'..owner_b..'/reading_state.json'
local scoped_before;failed_path=scoped_path
local stale_without_dispatch=BookStore.load(scoped,'book/42',index)
sync_events={}
local rename=os.rename
rawset(os,'rename',function(from,to) sync_events[#sync_events+1]='rename';return rename(from,to) end)
local synced=BookStore.patch_reading(scoped,'book/42',index,{source_dispatch={account=owner_b,id='scoped-marker'}})
rawset(os,'rename',rename)
expect(synced and #sync_events==6 and sync_events[1]=='file' and sync_events[2]=='rename'
    and sync_events[3]==index.cache_dir..'/.weread-accounts/'..owner_b
    and sync_events[4]==index.cache_dir..'/.weread-accounts'
    and sync_events[5]==index.cache_dir and sync_events[6]==root,
    'scoped dispatch did not synchronize file before rename and all created parent entries afterward')
sync_events={}
expect(BookStore.save(scoped,'book/42',stale_without_dispatch)
    and BookStore.load(scoped,'book/42',index).source_dispatch.id=='scoped-marker'
    and sync_events[1]=='file' and #sync_events>=2,'stale metadata save erased or failed to sync a pending dispatch')
local stale_with_dispatch=BookStore.load(scoped,'book/42',index)
expect(BookStore.patch_reading(scoped,'book/42',index,{source_dispatch=false}),
    'scoped dispatch could not be cleared')
expect(BookStore.save(scoped,'book/42',stale_with_dispatch)
    and not BookStore.load(scoped,'book/42',index).source_dispatch,
    'stale metadata save resurrected a confirmed dispatch')
local relative_tmp=os.tmpname();os.remove(relative_tmp)
local relative_name='weread-durable-'..assert(relative_tmp:match('([^/]+)$'))
local relative_settings={cache_dir='.',account_state_scope=function() return owner_b end}
local relative_saved,relative_index=BookStore.save(relative_settings,relative_name,{book_id=relative_name,cache_dir=relative_name})
expect(relative_saved,'relative cache fixture not saved')
sync_events={}
expect(BookStore.patch_reading(relative_settings,relative_name,relative_index,{source_dispatch={id='relative'}})
    and sync_events[#sync_events]=='.','relative cache parent directory was not synchronized')
local relative_accounts=relative_name..'/.weread-accounts/'
os.remove(relative_accounts..owner_b..'/reading_state.json');os.remove(relative_accounts..owner_b)
os.remove(relative_accounts);os.remove(relative_name..'/metadata.json');os.remove(relative_name)
scoped_before=bytes(scoped_path)
rawset(io,'open',close_failure_open)
local scoped_saved,scoped_error=BookStore.patch_reading(scoped,'book/42',index,{pending_upload_position={percent=99}})
rawset(io,'open',real_open)
expect(not scoped_saved and scoped_error=='synthetic delayed I/O failure' and bytes(scoped_path)==scoped_before
    and not exists(scoped_path..'.tmp') and bytes(index.cache_dir..'/reading_state.json')==old_state,
    'failed account checkpoint changed existing or legacy data')
local snapshot_path=index.cache_dir..'/.weread-accounts/legacy_metadata.json'
local snapshot_before,metadata_before=bytes(snapshot_path),bytes(index.cache_dir..'/metadata.json')
local bad_snapshot=assert(io.open(snapshot_path,'wb'));bad_snapshot:write('broken snapshot');bad_snapshot:close()
expect(not BookStore.save(scoped,'book/42',own_b) and bytes(snapshot_path)=='broken snapshot'
    and bytes(index.cache_dir..'/metadata.json')==metadata_before and bytes(scoped_path)==scoped_before,
    'corrupt legacy snapshot allowed metadata or account state to be overwritten')
local restore_snapshot=assert(io.open(snapshot_path,'wb'));restore_snapshot:write(snapshot_before);restore_snapshot:close()
active=owner_a
local own_a=BookStore.load(scoped,'book/42',index)
expect(own_a.pending_upload_position.percent==32 and own_a.last_local_position.percent==31
    and own_a.source_dispatch.id=='old-uncertainty','first account legacy checkpoint was lost')
expect(BookStore.patch_reading(scoped,'book/42',index,{pending_upload_position=false,pending_upload_reason=false}),
    'first account checkpoint could not be cleared')
expect(not BookStore.load(scoped,'book/42',index).pending_upload_position,'cleared legacy checkpoint reappeared')
active=owner_b;own_b=BookStore.load(scoped,'book/42',index)
expect(own_b.pending_upload_position.percent==61 and bytes(index.cache_dir..'/reading_state.json')==old_state,
    'first account update altered the other account or the legacy file')
local corrupt_scoped=assert(io.open(scoped_path,'wb'));corrupt_scoped:write('broken account state');corrupt_scoped:close()
expect(not BookStore.patch_reading(scoped,'book/42',index,{progress=99})
    and bytes(scoped_path)=='broken account state' and bytes(index.cache_dir..'/reading_state.json')==old_state,
    'corrupt account state was replaced or fell back to legacy')
local account_dir=index.cache_dir..'/.weread-accounts/'
for _,owner in ipairs({owner_a,owner_b}) do
    os.remove(account_dir..owner..'/reading_state.json');os.remove(account_dir..owner)
end
os.remove(account_dir..'legacy_metadata.json')
os.remove(account_dir)
os.remove(index.cache_dir..'/reading_state.json')
os.remove(index.cache_dir .. "/metadata.json")
os.remove(index.cache_dir)
os.remove(root)

print(("book_store_spec: %d checks"):format(checks))
