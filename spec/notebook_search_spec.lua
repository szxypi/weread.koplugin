package.path='./?.lua;'..package.path
local Search=require('weread.lib.notebook_search')
local function store(ids,rows)
    return {list_ids=function() return ids end,read=function(_,id) return rows[id] end}
end
local marks=store({'1','3'}, {
    ['1']={updated={{bookmarkId='m1',markText='A Needle in a chapter',chapterUid=7},
        {bookmarkId='m2',markText='Other',chapterUid=8}},chapters={{chapterUid=7,title='Synthetic chapter'}}},
    ['3']={updated={{bookmarkId='m3',markText='Needle in a cached extra book'}},chapters={}},
})
local thoughts=store({'2','3'}, {
    ['2']={reviews={{reviewId='t2',content='A note',abstract='Needle in a quotation',chapterName='Second'}}},
    ['3']={reviews={{reviewId='t3',content='Another needle'}}},
})
local catalog={{bookId='1'},{bookId='2'},{bookId='4'},{bookId='unsupported'}}
local out=Search.search(catalog,marks,thoughts,'needle')
assert(#out.items==4 and out.items[1].item_id=='m1' and out.items[2].item_id=='t2'
    and out.items[3].item_id=='m3' and out.items[4].item_id=='t3')
assert(out.available==4 and out.checked==4 and out.failed==0 and out.not_cached==4 and not out.truncated)
assert(out.items[1].preview=='A Needle in a chapter' and out.items[2].preview=='Needle in a quotation')
local long='😀'..string.rep('前',150)..' NEEdlE '..string.rep('后',100)
out=Search.search({{bookId='1'}},store({'1'},{['1']={updated={{bookmarkId='long',markText=long}},chapters={}}}),store({},{}),'needle')
local snippet=out.items[1].preview
assert(snippet:find('NEEdlE',1,true) and snippet:sub(1,3)=='…' and snippet:sub(-3)=='…')
assert(not snippet:find('😀',1,true) and #require('weread.lib.protocol').utf8_substr(snippet,82)==#snippet)
local at_end=string.rep('前',150)..'Needle'
out=Search.search({{bookId='1'}},store({'1'},{['1']={updated={{bookmarkId='end',markText=at_end}},chapters={}}}),store({},{}),'needle')
assert(out.items[1].preview:sub(-6)=='Needle' and out.items[1].preview:sub(1,3)=='…')
out=Search.search({{bookId='1'}},store({'1'},{['1']={updated={{bookmarkId='chapter',chapterUid=7}},
    chapters={{chapterUid=7,title=string.rep('章',90)..' needle\n标题'}}}}),store({},{}),'needle')
assert(out.items[1].preview:find('needle 标题',1,true) and not out.items[1].preview:find('\n',1,true))
out=Search.search(catalog,marks,thoughts,'synthetic chapter')
assert(#out.items==1 and out.items[1].item_id=='m1')
out=Search.search(catalog,store({'1'},{}),thoughts,'needle')
assert(out.failed==1 and out.checked==3 and #out.items==2)
local many={};for i=1,205 do many[i]={bookmarkId='i'..i,markText='matching text'} end
out=Search.search({{bookId='1'}},store({'1'},{['1']={updated=many,chapters={}}}),store({},{}),'matching')
assert(#out.items==200 and out.truncated and out.items[200].item_id=='i200')
assert(not pcall(Search.search,catalog,store(nil,{}),thoughts,'needle'))
print('PASS: cross-book saved notes search, coverage, invalid cache and bound')
