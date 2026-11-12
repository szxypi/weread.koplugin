package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local encoded_values = {}
local encoded_index = 0
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

local loaded = BookStore.load(settings, "book/42", index)
local metadata_only = BookStore.without_reading_state(loaded)
expect(metadata_only.title == loaded.title and metadata_only.cache_dir == loaded.cache_dir,
    "metadata filtering lost ordinary fields or cache paths")
expect(metadata_only.progress == nil and metadata_only.pending_upload_account == nil
    and metadata_only.source_dispatch == nil and loaded.progress == 37 and loaded.source_dispatch.id == "synthetic-receipt",
    "metadata filtering retained reading state or mutated its caller")
expect(BookStore.is_reading_field("pending_upload_position") and BookStore.is_reading_field("source_dispatch")
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

os.remove(index.cache_dir .. "/metadata.json")
os.remove(index.cache_dir)
os.remove(root)

print(("book_store_spec: %d checks"):format(checks))
