package.path='./?.lua;'..package.path
local Browse=require('weread.lib.shelf_browse')

local function state(values)
    local result={version=1,mode='books',page=2,group_keys={}}
    for key,value in pairs(values) do result[key]=value end
    return result
end

local saved=assert(Browse.normalize(state{keyword='合成书',group_keys={'local:2','archive:1'},
    book_id='9007199254740993',focus_book_id='CB_Synthetic',scroll_offset={x=10,y=913},inset=-1}))
assert(saved.mode=='books' and saved.group_keys[1]=='archive:1' and saved.book_id=='9007199254740993'
    and saved.focus_book_id=='CB_Synthetic' and saved.scroll_offset.x==0 and saved.scroll_offset.y==913 and saved.inset==-1)
assert(Browse.same(saved,Browse.normalize(saved)))
assert(not Browse.same(saved,Browse.normalize(state{keyword='合成书',group_keys={'local:2','archive:1'}})))
assert(not Browse.same_groups({'archive:2'},{'archive:1'}))
assert(Browse.normalize(state{mode='public_account',group_key='archive:3'}).group_key=='archive:3')

local combined=assert(Browse.normalize(state{filters={reading='progress_zero',download='not_downloaded'}}))
assert(combined.filters.reading=='progress_zero' and combined.filters.download=='not_downloaded')
assert(Browse.same(combined,Browse.normalize(combined)))
assert(not Browse.same(combined,Browse.normalize(state{filters={reading='progress_zero'}})))
local unfiltered=assert(Browse.normalize(state{filters={reading='invalid',download={}}}))
assert(next(unfiltered.filters)==nil and not Browse.same(unfiltered,Browse.normalize(state{})))
assert(not Browse.normalize(state{mode='public_account',filters=combined.filters}).filters)

for _,invalid in ipairs({{version=2},{mode='other'},{page=0},{page=2.1},{page=99999999},{keyword=string.rep('x',1025)},
    {keyword='line\nbreak'},{keyword='bad\255'},{group_key=''}, {group_key='archive:2',group_keys={'archive:1'}},
    {group_keys={'local:2','local:2'}},{group_keys={untrusted='local:2'}}}) do
    assert(not Browse.normalize(state(invalid)))
end
local safe=assert(Browse.normalize(state{book_id=999999999999999,focus_book_id={},scroll_offset={y=math.huge},inset=-2}))
assert(not safe.book_id and not safe.focus_book_id and not safe.scroll_offset and not safe.inset)
print('shelf_browse_spec: persisted position, exact identities, groups and malformed state passed')
