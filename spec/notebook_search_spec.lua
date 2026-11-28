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
local function note_preview(text,query)
    local source=store({'1'},{['1']={updated={{bookmarkId='preview',markText=text}},chapters={}}})
    return Search.search({{bookId='1'}},source,store({},{}),query).items[1].preview
end
local exact_length=string.rep('先',79)..'末'
assert(note_preview(exact_length,'末')==exact_length,'80 characters should display in full')
local leading=string.rep('先',100)..'😀乙丙关键'..string.rep('尾',100)
assert(note_preview(leading,'关键')=='…😀乙丙关键'..string.rep('尾',75)..'…',
    'offset did not preserve the three original characters before the match')
local original_case=string.rep('前',100)..'😀乙丙NEEDLE'..string.rep('后',100)
assert(note_preview(original_case,'needle'):find('😀乙丙NEEDLE',1,true),
    'case folding changed the text or the size of the context')
local long_tail=string.rep('长',43685)..'😀甲乙关键'
assert(note_preview(long_tail,'关键')=='…😀甲乙关键',
    'the end of a maximum-sized note lost original context')
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
local large={};for i=1,405 do large[i]={bookmarkId='id'..i,markText='matching text'} end
local collection=store({'1'},{['1']={updated=large,chapters={}}})
local empty=store({},{})
local first=Search.search({{bookId='1'}},collection,empty,'matching')
assert(first.truncated and first.next_cursor.offset==200 and first.items[200].item_id=='id200')
local second=Search.search({{bookId='1'}},collection,empty,'matching',first.next_cursor)
assert(second.truncated and second.next_cursor.offset==400 and second.items[1].item_id=='id201' and second.items[200].item_id=='id400')
local third=Search.search({{bookId='1'}},collection,empty,'matching',second.next_cursor)
assert(not third.truncated and not third.next_cursor and #third.items==5 and third.items[1].item_id=='id401')
large[20].markText='different'
assert(Search.search({{bookId='1'}},collection,empty,'matching',first.next_cursor).changed)
large[20].markText='matching text'
large[220].bookmarkId='changed'
assert(Search.search({{bookId='1'}},collection,empty,'matching',second.next_cursor).changed)
large[220].bookmarkId='id220'
local exact={};for i=1,400 do exact[i]={bookmarkId='e'..i,markText='matching'} end
local exact_store=store({'1'},{['1']={updated=exact,chapters={}}})
local full=Search.search({{bookId='1'}},exact_store,empty,'matching')
local last=Search.search({{bookId='1'}},exact_store,empty,'matching',full.next_cursor)
assert(#last.items==200 and not last.truncated and last.next_cursor==nil)
for i=400,100,-1 do exact[i]=nil end
assert(Search.search({{bookId='1'}},exact_store,empty,'matching',full.next_cursor).changed)
assert(not pcall(Search.search,{},empty,empty,'matching',{offset=1,digest=string.rep('0',64)}))
assert(not pcall(Search.search,catalog,store(nil,{}),thoughts,'needle'))
print('PASS: cross-book saved notes search, coverage, invalid cache and bound')
