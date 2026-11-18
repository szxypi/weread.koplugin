-- Project user-defined WeRead shelf groups onto the current shelf snapshot.

local Groups = {}

local function text(value, fallback)
    if type(value) ~= "string" then return fallback end
    value = value:match("^%s*(.-)%s*$")
    return value ~= "" and value or fallback
end

local function group_key(archive, label)
    local id = archive.archiveId or archive.archive_id or archive.id
    if id ~= nil and tostring(id) ~= "" then return "archive:" .. tostring(id) end
    return "name:" .. label
end

function Groups.list(archives, books, unnamed_label, ungrouped_label)
    local system_identity_count = 0
    for _, archive in ipairs(type(archives) == "table" and archives or {}) do
        if type(archive) == "table" and tostring(archive.archiveId or archive.archive_id or archive.id) == "1" then
            system_identity_count = system_identity_count + 1
        end
    end
    local by_id = {}
    for _, book in ipairs(type(books) == "table" and books or {}) do
        local id = book.book_id or book.bookId
        if id then by_id[tostring(id)] = book end
    end

    local groups = {}
    local grouped = {}
    for _, source_archive in ipairs(type(archives) == "table" and archives or {}) do
        local archive = type(source_archive) == "table" and source_archive or {}
        local ids = type(archive.bookIds) == "table" and archive.bookIds or {}
        local label = text(archive.name, unnamed_label or "Unnamed group")
        -- The client may expose a system archive as a carrier for otherwise
        -- ungrouped books. Keep it selectable, but do not treat its members
        -- alone as assigned to a user group. Both identity and label must
        -- match; an ordinary group named "归档" remains an ordinary group.
        local identity = archive.archiveId or archive.archive_id or archive.id
        local system_archive = system_identity_count == 1 and tostring(identity) == "1" and label == "归档"
        local members, seen = {}, {}
        local mp_only = #ids > 0
        for _, id in ipairs(ids) do
            id = tostring(id)
            if id:sub(1,7) ~= 'MP_WXS_' then mp_only = false end
            local book = by_id[id]
            if book and not seen[id] then
                members[#members + 1] = book
                seen[id] = true
                if not system_archive then grouped[id] = true end
            end
        end
        -- Public-account archives contain no regular books. The original
        -- bookshelf already exposes those separately, so do not add a ghost
        -- group for them. Empty user-created groups stay visible.
        if #members > 0 or not mp_only then
            groups[#groups + 1] = {
                key = group_key(archive, label),
                label = label,
                books = members,
            }
        end
    end
    local ungrouped = {}
    for _, book in ipairs(type(books) == "table" and books or {}) do
        local id = book.book_id or book.bookId
        if id and not grouped[tostring(id)] then ungrouped[#ungrouped + 1] = book end
    end
    if #groups > 0 and #ungrouped > 0 then
        groups[#groups + 1] = {
            key = "__ungrouped__",
            label = ungrouped_label or "Uncategorized",
            books = ungrouped,
        }
    end
    return groups
end

function Groups.find(groups, key)
    for _, group in ipairs(type(groups) == "table" and groups or {}) do
        if group.key == key then return group end
    end
end

-- Stored keys are account-local and must not silently select an ambiguous
-- archive when a server snapshot has duplicate or missing identifiers.
function Groups.normalize(keys)
    if type(keys)~='table' or #keys>1000 then return nil end
    local result,seen,count={},{},0
    for key in pairs(keys) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#keys then return nil end
        count=count+1
    end
    if count~=#keys then return nil end
    for _,key in ipairs(keys) do
        if type(key)~='string' or key=='' or #key>512 or key:find('[%z%c]') or seen[key] then return nil end
        seen[key]=true;result[#result+1]=key
    end
    table.sort(result);return result
end

function Groups.unique(groups,key)
    local found
    for _,group in ipairs(type(groups)=='table' and groups or {}) do
        if group.key==key then if found then return nil end;found=group end
    end
    return found
end

-- Preserve shelf order and use each book once even when groups overlap.
-- If any remembered group is absent or ambiguous, leave the full shelf visible
-- and keep the selection for a later complete snapshot.
function Groups.selected(groups,keys,books)
    keys=Groups.normalize(keys)
    if not keys or #keys==0 then return nil,keys and 'all' or 'invalid' end
    local members={}
    for _,key in ipairs(keys) do
        local group=Groups.unique(groups,key)
        if not group then return nil,'unavailable' end
        for _,book in ipairs(group.books or {}) do
            local id=book.book_id or book.bookId
            if id~=nil then members[tostring(id)]=true end
        end
    end
    local result,seen={},{}
    for _,book in ipairs(type(books)=='table' and books or {}) do
        local id=book.book_id or book.bookId;id=id and tostring(id)
        if id and members[id] and not seen[id] then result[#result+1]=book;seen[id]=true end
    end
    return result,'selected'
end

return Groups
