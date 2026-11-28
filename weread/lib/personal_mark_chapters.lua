-- The snapshots are immutable projections. Retain only row references, and
-- rebuild when a new projection is installed rather than rescanning every
-- chapter on each navigation.
local M={}
local EMPTY={}

function M.rows(state,field,uid)
    local snapshot=state[field]
    local cache_key=field=='snapshot' and '_mark_chapters' or '_thought_chapters'
    if not snapshot then state[cache_key]=nil;return EMPTY end
    local index=state[cache_key]
    if not index or index.snapshot~=snapshot then
        index={snapshot=snapshot,chapters={}}
        local rows=field=='snapshot' and snapshot.updated or snapshot.reviews
        index.rows=rows or EMPTY
        for i,row in ipairs(index.rows) do
            local chapter=tostring(row.chapterUid)
            local group=index.chapters[chapter]
            if not group then
                -- Most chapters can have just one note. An integer avoids
                -- retaining a separate Lua table for every singleton.
                index.chapters[chapter]=i
            elseif type(group)=='number' then
                index.chapters[chapter]={index.rows[group],row}
            else
                group[#group+1]=row
            end
        end
        state[cache_key]=index
    end
    local group=index.chapters[uid]
    if type(group)=='number' then
        if index.last_uid~=uid then index.last_uid=uid;index.last_rows={index.rows[group]} end
        return index.last_rows
    end
    return group or EMPTY
end

return M
