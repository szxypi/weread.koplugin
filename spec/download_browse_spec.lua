package.path='./?.lua;'..package.path
local Browse=require('weread.lib.download_browse')

local empty=Browse.new()
assert(Browse.same(empty,Browse.normalize(empty)) and Browse.positions(empty)==empty.unfiltered)
local saved=Browse.normalize{version=1,copy_type='eink',query='离线书',
    unfiltered={all={anchor=8,book_id='9007199254740993',focus_book_id='CB_Test'},
        eink={anchor=-1,book_id='bad\0id'},other={anchor=1}},
    matches={standard={anchor=2,focus_book_id='41'}}}
assert(saved.copy_type=='eink' and saved.query=='离线书' and Browse.positions(saved)==saved.matches)
assert(saved.unfiltered.all.anchor==8 and saved.unfiltered.all.book_id=='9007199254740993'
    and saved.unfiltered.all.focus_book_id=='CB_Test' and not saved.unfiltered.eink and not saved.unfiltered.other)
assert(saved.matches.standard.focus_book_id=='41')
local copied=Browse.normalize(saved)
assert(Browse.same(saved,copied) and saved~=copied and saved.unfiltered.all~=copied.unfiltered.all)
copied.unfiltered.all.anchor=9;assert(not Browse.same(saved,copied))
copied.query='';copied=Browse.normalize(copied)
assert(next(copied.matches)==nil and Browse.positions(copied)==copied.unfiltered)
for _,bad in ipairs({{version=2,copy_type='all',query=''}, {version=1,copy_type='wrong',query=''},
    {version=1,copy_type='all',query='bad\0search'}, {version=1,copy_type='all',query=string.rep('a',1025)}}) do
    assert(not Browse.normalize(bad))
end
print('download_browse_spec: separate filter positions, exact book IDs and malformed state passed')
