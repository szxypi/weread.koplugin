package.path='./?.lua;'..package.path
local Guard=require('weread.lib.cb_readtime_guard')
local Crypto=require('weread.lib.readtime_transfer_contract')
local count=0
local function expect(value) count=count+1;assert(value,'check '..count) end
local function raw()
    return {book={bookId='CB_Synthetic',chapterUid=7,chapterIdx=1,chapterOffset=12,progress=10,
        summary='完整摘要\n😀',chapterTitle='标题',readingTime=2,recordReadingTime=0,ttsTime=0}}
end
local first,second=raw(),raw()
local accepted=Guard.observe(first,second,'CB_Synthetic')
expect(accepted and accepted.summary=='完整摘要\n😀' and Crypto.hash(accepted.native_hash) and Crypto.hash(accepted.web_hash))
expect(accepted.native_hash==accepted.web_hash)
for _i,field in ipairs({'chapterUid','chapterIdx','chapterOffset','progress','summary'}) do
    local altered=raw();altered.book[field]=field=='summary' and '不同摘要' or 99
    expect(not Guard.observe(first,altered,'CB_Synthetic'))
    expect(not Guard.observe(altered,second,'CB_Synthetic'))
end
for _i,field in ipairs({'chapterUid','chapterIdx','chapterOffset','progress','summary'}) do
    local missing=raw();missing.book[field]=nil
    expect(not Guard.observe(first,missing,'CB_Synthetic'))
    expect(not Guard.observe(missing,second,'CB_Synthetic'))
end
for _i,bad in ipairs({'','a\0b',string.rep('文',513),'\255'}) do
    local a,b=raw(),raw();a.book.summary=bad;b.book.summary=bad
    expect(not Guard.observe(a,b,'CB_Synthetic'))
end
for _i,bad in ipairs({'42','CB_','CB_no/','CB_'..string.rep('x',65)}) do
    expect(not Guard.observe(first,second,bad))
end
local other=raw();other.book.bookId='CB_Other';expect(not Guard.observe(other,second,'CB_Synthetic'))
local title=raw();title.book.chapterTitle='不同标题';local observed=Guard.observe(first,title,'CB_Synthetic')
expect(observed and observed.summary==accepted.summary and observed.web_hash~=accepted.web_hash)
local counters=raw();counters.book.readingTime=3
expect(Guard.observe(first,counters,'CB_Synthetic').web_hash==accepted.web_hash)
expect(not Guard.observe(nil,nil,'CB_Synthetic'))
print('cb_readtime_guard_spec: '..count..' checks')
