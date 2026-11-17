local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local BookStore = {}

local reading_fields = {
    app_id = true,
    chapter_idx = true,
    chapter_offset = true,
    chapter_uid = true,
    last_local_position = true,
    last_local_account = true,
    home_recent_at = true,
    home_recent_account = true,
    native_location_claims = true,
    unindexed_resume = true,
    last_pull_at = true,
    last_remote_position = true,
    last_sync_error = true,
    last_upload_at = true,
    last_uploaded_position = true,
    pclts = true,
    pending_upload_position = true,
    pending_upload_reason = true,
    pending_upload_account = true,
    source_dispatch = true,
    progress = true,
    psvts = true,
    read_context_updated_at = true,
    read_session_entered_at = true,
    read_session_id = true,
    reader_url = true,
    summary = true,
    token = true,
    verified_at = true,
    verified_source = true,
}

local article_fields = {
    mp_articles = true,
    mp_articles_time = true,
}

-- Reading state has one owner: the latest per-book checkpoint. Metadata
-- snapshots must neither restore cleared fields nor overwrite newer ones.
function BookStore.is_reading_field(key)
    return reading_fields[key] == true
end

function BookStore.without_reading_state(book)
    local metadata = {}
    for key, value in pairs(book) do
        if not reading_fields[key] then metadata[key] = value end
    end
    return metadata
end

local function basename_safe(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    return value ~= "" and value or "weread"
end

local function dirname(path)
    if type(path) == "string" then
        return path:match("^(.*)/[^/]+$")
    end
end

local function resolved_dir(settings, book_id, book)
    if type(book) == "table" and type(book.cache_dir) == "string" and book.cache_dir ~= "" then
        return book.cache_dir
    end
    local dir = type(book) == "table"
        and dirname(book.cached_full_book or book.cached_file) or nil
    if not dir and type(book) == "table" and type(book.cached_chapters) == "table" then
        for _uid, path in pairs(book.cached_chapters) do
            dir = dirname(path)
            if dir then break end
        end
    end
    return dir or (settings.cache_dir .. "/" .. basename_safe(book_id))
end

local function encode(value)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(value)
    end
    return json:encode(value)
end

local function decode(value)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(value)
    end
    return json:decode(value)
end

local function read_json(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local ok, value = pcall(decode, content)
    return ok and type(value) == "table" and value or nil
end

local function write_json(path, value)
    local ok, content = pcall(encode, value)
    if not ok then return false, content end
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "wb")
    if not file then return false, err end
    local write_ok, write_err = file:write(content)
    -- Buffered writes may succeed while fclose reports the actual I/O error.
    -- Never publish that incomplete state or grant a dispatch receipt for it.
    local close_ok, close_err = file:close()
    if not write_ok or not close_ok then
        os.remove(tmp_path)
        return false, write_err or close_err
    end
    local rename_ok, rename_err = os.rename(tmp_path, path)
    if not rename_ok then
        os.remove(tmp_path)
        return false, rename_err
    end
    return true
end

local function merge(target, source)
    for key, value in pairs(source or {}) do
        target[key] = value
    end
end

local function has_values(value)
    return next(value) ~= nil
end

local function exists(path)
    local file=io.open(path,'rb');if not file then return false end
    file:close();return true
end

local function scoped_path(settings,dir)
    if type(settings.account_state_scope)~='function' then return nil end
    local scope=settings:account_state_scope()
    if scope~='anonymous' and (type(scope)~='string' or #scope~=20 or not scope:match('^[a-f0-9]+$')) then
        return false
    end
    return dir..'/.weread-accounts/'..scope..'/reading_state.json',scope
end

local function scoped_state(dir,metadata,path,scope)
    local state=read_json(path)
    if state then return state end
    if exists(path) then return nil,'invalid account reading state' end
    local legacy_path=dir..'/reading_state.json'
    local legacy=read_json(legacy_path)
    if not legacy and exists(legacy_path) then return nil,'invalid legacy reading state' end
    local snapshot_path=dir..'/.weread-accounts/legacy_metadata.json'
    local snapshot=read_json(snapshot_path)
    if not snapshot and exists(snapshot_path) then return nil,'invalid legacy metadata snapshot' end
    metadata=snapshot or metadata
    return require('weread.lib.account_book_state').legacy(metadata,legacy,reading_fields,scope)
end

local function make_dir(dir)
    local quote="'"..dir:gsub("'", "'\\''").."'"
    local ok=os.execute('mkdir -p '..quote)
    return ok==true or ok==0
end

local function make_parent(path) return make_dir(assert(dirname(path))) end

local function preserve_legacy_metadata(dir,metadata)
    local path=dir..'/.weread-accounts/legacy_metadata.json'
    if exists(path) then
        return read_json(path)~=nil,'invalid legacy metadata snapshot'
    end
    local legacy=exists(dir..'/reading_state.json')
    local snapshot={}
    for key,value in pairs(metadata or {}) do
        if reading_fields[key] or key=='recent_read_account' or key=='recent_read_at' or key=='_library_account_key' then
            snapshot[key]=value
            if reading_fields[key] or key=='recent_read_at' then legacy=true end
        end
    end
    if not legacy then return true end
    if not make_parent(path) then return false,'could not create legacy metadata directory' end
    return write_json(path,snapshot)
end

function BookStore.load(settings, book_id, index)
    local book = {}
    merge(book, index)
    local dir = resolved_dir(settings, book_id, index)
    local metadata=read_json(dir .. "/metadata.json")
    merge(book,metadata)
    local path,scope=scoped_path(settings,dir)
    if path~=nil then
        for key in pairs(reading_fields) do book[key]=nil end
        if path then merge(book,scoped_state(dir,metadata,path,scope)) end
    elseif path==nil then merge(book,read_json(dir .. "/reading_state.json")) end
    merge(book, read_json(dir .. "/articles.json"))
    book.book_id = book.book_id or book.bookId or tostring(book_id)
    book.cache_dir = dir
    return book
end

-- Late reader jobs update one bounded state file, never an older in-memory
-- copy of the global settings, metadata or another book's state.
function BookStore.patch_reading(settings, book_id, index, patch)
    if type(index) ~= 'table' or type(patch) ~= 'table' then return false, 'missing book index' end
    for key in pairs(patch) do if not reading_fields[key] then return false, 'not a reading-state field' end end
    local dir=resolved_dir(settings,book_id,index)
    local path,scope=scoped_path(settings,dir)
    if path==false then return false,'invalid reading account scope' end
    local state,err
    if path then
        state,err=scoped_state(dir,read_json(dir..'/metadata.json'),path,scope)
        if not state then return false,err end
        if not make_parent(path) then return false,'could not create reading state directory' end
    else
        path=dir..'/reading_state.json';state=read_json(path)
        if not state and exists(path) then return false,'invalid reading state' end
        state=state or {}
    end
    for key,value in pairs(patch) do state[key] = value ~= false and value or nil end
    return write_json(path,state)
end

function BookStore.save(settings, book_id, book)
    book = type(book) == "table" and book or {}
    local dir = resolved_dir(settings, book_id, book)
    if not make_dir(dir) then return false,'could not create book directory' end

    local path,scope=scoped_path(settings,dir)
    if path==false then return false,'invalid reading account scope' end
    if path then
        local metadata_path=dir..'/metadata.json'
        local previous_metadata=read_json(metadata_path)
        if not previous_metadata and exists(metadata_path) then return false,'invalid book metadata' end
        local _,state_err=scoped_state(dir,previous_metadata,path,scope)
        if state_err then return false,state_err end
        if not make_parent(path) then return false,'could not create reading state directory' end
        local preserved,preserve_err=preserve_legacy_metadata(dir,previous_metadata)
        if not preserved then return false,preserve_err end
    end

    local metadata = { book_id = book.book_id or book.bookId or tostring(book_id) }
    local reading_state = {}
    local articles = {}
    for key, value in pairs(book) do
        if article_fields[key] then
            articles[key] = value
        elseif reading_fields[key] then
            reading_state[key] = value
        elseif key ~= "chapters" and key ~= "cache_dir" and key ~= "bookId" then
            metadata[key] = value
        end
    end

    local ok, err = write_json(dir .. "/metadata.json", metadata)
    if not ok then return false, err end
    if path or has_values(reading_state) then
        ok, err = write_json(path or dir .. "/reading_state.json", reading_state)
        if not ok then return false, err end
    else
        os.remove(dir .. "/reading_state.json")
    end
    if has_values(articles) then
        ok, err = write_json(dir .. "/articles.json", articles)
        if not ok then return false, err end
    else
        os.remove(dir .. "/articles.json")
    end
    return true, { cache_dir = dir }
end

-- Cache removal must not round-trip a stale reading_state.json snapshot. A
-- closed-reader report may still be patching its journal independently.
function BookStore.clear_downloads(settings, book_id, index, expected)
    local dir=resolved_dir(settings,book_id,index)
    local path=dir..'/metadata.json'
    local file=io.open(path,'rb');if not file then return false,'unavailable book metadata' end
    local raw=file:read(2*1024*1024+1);file:close()
    if not raw or #raw>2*1024*1024 or expected and raw~=expected then return false,'changed book metadata' end
    local ok,metadata=pcall(decode,raw)
    if not ok or type(metadata)~='table' or tostring(metadata.book_id or metadata.bookId or '')~=tostring(book_id)
        or metadata.cached_chapters~=nil and type(metadata.cached_chapters)~='table'
        or metadata.annotation_documents~=nil and type(metadata.annotation_documents)~='table' then return false,'invalid book metadata' end
    for _i,key in ipairs({'cached_file','cached_full_book'}) do
        if type(metadata[key])~='string' or not exists(metadata[key]) then metadata[key]=nil end
    end
    local chapters={}
    for uid,filename in pairs(metadata.cached_chapters or {}) do
        if type(filename)=='string' and exists(filename) then chapters[uid]=filename end
    end
    metadata.cached_chapters=next(chapters) and chapters or nil
    local annotations={}
    for filename,value in pairs(metadata.annotation_documents or {}) do
        if type(filename)=='string' and exists(filename) then annotations[filename]=value end
    end
    metadata.annotation_documents=next(annotations) and annotations or nil
    return write_json(path,metadata)
end

function BookStore.is_minimal_index(books)
    for _book_id, record in pairs(books or {}) do
        if type(record) ~= "table" then return false end
        for key in pairs(record) do
            if key ~= "cache_dir" then return false end
        end
    end
    return true
end

return BookStore
