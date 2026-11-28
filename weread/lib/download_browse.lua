local Protocol=require('weread.lib.protocol')
local ShelfSnapshot=require('weread.lib.shelf_snapshot')
local M={KEY='download_library_browse_v1',copy_types={'all','standard','eink','both'}}
local known={all=true,standard=true,eink=true,both=true}

function M.new()
    return {version=1,copy_type='all',query='',unfiltered={},matches={}}
end

function M.positions(browse)
    return browse.query=='' and browse.unfiltered or browse.matches
end

local function position_map(value)
    local positions={}
    if type(value)~='table' then return positions end
    for _,kind in ipairs(M.copy_types) do
        local position=value[kind]
        if type(position)=='table' then
            local anchor=position.anchor
            if type(anchor)~='number' or not (anchor>=1 and anchor%1==0) then anchor=nil end
            local book=ShelfSnapshot.persisted_identity(position.book_id)
            local focus=ShelfSnapshot.persisted_identity(position.focus_book_id)
            if anchor or book or focus then positions[kind]={anchor=anchor,book_id=book,focus_book_id=focus} end
        end
    end
    return positions
end

function M.normalize(value)
    if type(value)~='table' or value.version~=1 or not known[value.copy_type] then return end
    local query=value.query
    if type(query)~='string' or #query>1024 or query:find('[%z%c]')
        or Protocol.utf8_substr(query,#query)~=query then return end
    return {version=1,copy_type=value.copy_type,query=query,unfiltered=position_map(value.unfiltered),
        matches=query~='' and position_map(value.matches) or {}}
end

local function same_positions(left,right)
    for _,kind in ipairs(M.copy_types) do
        local a,b=left[kind],right[kind]
        if (a==nil)~=(b==nil) then return false end
        if a and (a.anchor~=b.anchor or a.book_id~=b.book_id or a.focus_book_id~=b.focus_book_id) then return false end
    end
    return true
end

function M.same(a,b)
    return a and b and a.copy_type==b.copy_type and a.query==b.query
        and same_positions(a.unfiltered,b.unfiltered) and same_positions(a.matches,b.matches)
end

return M
