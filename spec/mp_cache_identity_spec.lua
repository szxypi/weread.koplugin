package.path='./?.lua;'..package.path
local Cache=require('weread.lib.mp_cache_identity')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local book={book_id='MP_WXS_42'}
local one={reviewId='a/b',title='Same title'}
local two={reviewId='a_b',title='Same title'}
local key=assert(Cache.key(book,one));expect(#key==64 and key:match('^[a-f0-9]+$'),'bounded hash absent')
expect(key~=Cache.key(book,two),'sanitized ID collision')
one.title='Renamed';expect(Cache.key(book,one)==key,'title change orphaned article')
expect(Cache.key({book_id='MP_WXS_43'},one)~=key,'account-container isolation lost')
expect(Cache.key(book,{reviewId='a/b',bookId='MP_WXS_42'})==key,'default source changed key')
expect(Cache.key(book,{reviewId='a/b',bookId='MP_WXS_43'})~=key,'independent source binding lost')
expect(Cache.key(book,{originalId='a/b'})~=key,'original ID confused with review ID')
expect(Cache.key(book,{reviewId='',originalId='a/b'})==Cache.key(book,{originalId='a/b'}),'empty primary ID blocked original fallback')
expect(Cache.key(book,{reviewId=123})==Cache.key(book,{reviewId='123'}),'numeric identifier did not canonicalize')
expect(Cache.key(book,{reviewId=9007199254740991})==Cache.key(book,{reviewId='9007199254740991'}),'large exact integer lost decimal identity')
for _,bad in ipairs({{title='only title'},{reviewId=true},{reviewId={}},{reviewId='x\0y'},{reviewId='two words'},
    {reviewId=0/0},{reviewId=math.huge},{reviewId=string.rep('x',513)},{reviewId='valid',bookId=true}}) do expect(not Cache.key(book,bad),'invalid article identity accepted') end
expect(not Cache.key({book_id='42',bookId='43'},one),'contradictory container accepted')
local path=assert(Cache.path('/root/',key))
expect(path=='/root/mp-articles/'..key..'/article.html','path is not stable or scoped')
expect(not path:find('Renamed',1,true) and not path:find('a/b',1,true),'raw identity/title entered filename')
for _,root in ipairs({'','x\0y',string.rep('x',3501)}) do expect(not Cache.path(root,key),'invalid root accepted') end
expect(not Cache.path('/root','../escape'),'invalid hash accepted')
expect(Cache.marker(key):find(key,1,true),'identity header absent')
local function name(row) return row.title:gsub('[/:?]','_') end
one.title='Same title'
expect(Cache.legacy_allowed(book,one,{one},name),'unique legacy record lost')
expect(Cache.legacy_allowed(book,one,{one,one},name),'duplicate same-ID record considered ambiguous')
local allowed,reason=Cache.legacy_allowed(book,one,{one,two},name)
expect(not allowed and reason=='ambiguous_legacy','same title legacy associated with wrong ID')
local a,b={reviewId='a',title='A/B'},{reviewId='b',title='A?B'}
allowed,reason=Cache.legacy_allowed(book,a,{a,b},name)
expect(not allowed and reason=='ambiguous_legacy','sanitized legacy filenames considered distinct')
expect(not Cache.legacy_allowed(book,one,{},name),'unlisted legacy article accepted')
expect(not Cache.legacy_allowed(book,one,nil,name),'no-catalog legacy guessed')
local max=Cache.MAX_CATALOG;Cache.MAX_CATALOG=1
expect(not Cache.legacy_allowed(book,one,{one,one},name),'oversized legacy association accepted');Cache.MAX_CATALOG=max
print('PASS: MP article cache identity ('..checks..' checks)')
