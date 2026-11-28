package.path='./?.lua;./?/init.lua;'..package.path
local Info=require('weread.lib.public_book_info')
local Protocol=require('weread.lib.protocol')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local info=assert(Info.project{intro='First line\nSecond line',publisher='Publisher',translator='Translator',
    newRating=860,newRatingCount=12,token='private',progress=12})
expect(info.intro=='First line\nSecond line' and info.publisher=='Publisher' and info.translator=='Translator'
    and info.newRating==860 and info.newRatingCount==12 and not info.token and not info.progress,
    'public projection lost fields or retained private state')
local long=string.rep('中',1000)
info=assert(Info.project{intro=long})
expect(#info.intro<=Info.INTRO_LIMIT and info.intro:sub(-3)=='…'
    and Protocol.utf8_substr(info.intro,#info.intro+1)==info.intro,'long excerpt split UTF-8 or lost ellipsis')
expect(not Info.project{intro='bad\0text',publisher=string.char(255),translator=string.rep('x',513),
    newRating=0/0,newRatingCount=math.huge},'invalid public fields were accepted')
info=assert(Info.project{intro='First\tline\n第二行 😀',publisher='bad\tlabel',translator='bad\nlabel'})
expect(info.intro=='First\tline\n第二行 😀' and not info.publisher and not info.translator,
    'body and label control policies diverged')
expect(not Info.project{intro='First\r\nSecond'},'carriage return accepted in public summary')
for _,tail in ipairs({'\0','\r','\192\128','\237\160\128','\244\144\128\128','\240\159\152'}) do
    expect(not Info.project{intro=long..tail},'summary with an invalid tail was truncated and accepted')
end
expect(not Info.project{intro=string.rep('x',65537)} and not Info.project(false),'oversized or invalid info accepted')
expect(not Info.project{newRating=860} and not Info.project{newRatingCount=12}
    and not Info.project{newRating=860,newRatingCount=1.5},
    'incomplete rating was displayed with an invented count')
local data={results={{books={
    {bookInfo={bookId='1',title='One',intro='First',token='secret'},searchIdx=1},
    {bookInfo={bookId='1',title='Duplicate',intro='Second'},searchIdx=2},
    {book={bookInfo={bookId='2',title='Two',publisher='Other'}},searchIdx=3},
}}}}
local page={books={{bookId='1'},{bookId='2'},{bookId='3'}}}
Info.attach(page,data)
expect(page.books[1]._public_info.intro=='First' and not page.books[1]._public_info.token
    and page.books[2]._public_info.publisher=='Other' and not page.books[3]._public_info,
    'public metadata was attached to the wrong result')
print('public_book_info_spec: '..checks..' checks')
