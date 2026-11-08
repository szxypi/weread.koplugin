package.path='./?.lua;'..package.path
package.preload['weread.lib.logger']=function() return {info=function() end,warn=function() end} end
local Context=require('weread.lib.reader_context')
local Protocol=require('weread.lib.protocol')
local Content=require('weread.lib.content')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function rejected(reason,task)
    local ok,err=pcall(task);expect(not ok and err=='reader_context/'..reason,'did not reject '..reason)
end
local root=Protocol.reader_url('900001')
local chapter_url=Protocol.reader_url('900001',2)
local book={book_id='900001',bookId=900001,reader_url='https://example.invalid/stale',title='Keep local title',chapter_offset=77,
    psvts='old',pclts='old',token='old',cached_file='/synthetic/kept.epub',pending_upload_position={percent=88}}
local initial
local html='window.__INITIAL_STATE__ = {};(function(){})();'
local function fixture()
    initial={reader={bookInfo={bookId='900001',title='Synthetic',author='Author'},psvts='synthetic-psvts',pclts=0,token='synthetic-token',
        currentChapter={chapterUid=2,chapterOffset=12},progress={book={bookId='900001',progress=10}}}}
end
fixture()
expect(Context.book_id(book)=='900001','equivalent ID aliases rejected')
for _,value in ipairs({{}, {book_id='42',bookId='43'}, {book_id=false}, {book_id='0'}, {book_id='../book'}, {book_id='MP_WXS_12'}}) do
    rejected('invalid_identity',function() Context.book_id(value) end)
end
expect(Context.identifier('abc012')=='abc012' and Context.identifier(0,true)=='0','opaque ID or chapter zero rejected')
for _,url in ipairs({'https://example.invalid',Protocol.reader_url('900002'),root..'/extra',root..'\n',
    'http://weread.qq.com/'..root,'https://weread.qq.com:443/'..root}) do
    expect(Context.url({book_id='900001',reader_url=url})==root,'stale or invalid URL was reused')
end
expect(Context.url({book_id='900001',reader_url=chapter_url..'?wvid=discard#discard'})==chapter_url,'selected chapter or sharing normalization wrong')
expect(Context.url({book_id='900001',reader_url=root},2)==chapter_url,'explicit chapter did not override cached URL')
expect(Context.url({book_id='900001',reader_url=root:gsub('https://weread.qq.com','HTTPS://WEREAD.QQ.COM')})==root,'case-insensitive origin rejected')
local function project() return Context.project(book,html,function() return initial end) end
local state=project()
expect(state.pclts==0 and state.book_id=='900001' and state.progress.progress==10,'valid zero/session/position lost')
initial.reader.bookInfo.bookId='900002';rejected('book_mismatch',project);fixture()
initial.reader.currentChapter.bookId='900002';rejected('book_mismatch',project);fixture()
initial.reader.progress.book.bookId='900002';rejected('book_mismatch',project);fixture()
for _,key in ipairs({'psvts','token','pclts'}) do
    initial.reader[key]={private='not a scalar'};rejected('invalid_session',project);fixture()
end
initial.reader.psvts=nil;rejected('invalid_session',project);fixture()
initial.reader.pclts=nil;initial.reader.token=nil
expect(project().pclts==nil and project().token==nil,'missing optional session fields were invented');fixture()
rejected('invalid_response',function() Context.project(book,'<script>{"bookId":"900001","psvts":"fake"}</script>',function() error('private parser input') end) end)
rejected('invalid_response',function() Context.project(book,string.rep('x',Context.MAX_HTML_BYTES+1),function() return initial end) end)
local requests={}
local client={json_decode=function() return initial end,
    get_text=function(_self,url,options) requests[#requests+1]={url=url,options=options};return html end,
    post_json=function(_self,url,body,options) requests[#requests+1]={url=url,body=body,options=options};return {{bookId='900001',updated={}}} end}
Content.ensure_reader_state(client,book)
expect(requests[1].url==root and requests[1].options.referer==root and requests[1].options.sensitive,'download used cached URL or unredacted diagnostics')
expect(book.reader_url==root and book.title=='Keep local title' and book.psvts=='synthetic-psvts' and book.pclts==0,'successful context merge wrong')
expect(book.cached_file=='/synthetic/kept.epub' and book.pending_upload_position.percent==88,'download state replaced')
Content.refresh_reader_state(client,book,{chapterUid=2})
expect(requests[#requests].url==chapter_url,'chapter refresh dropped the selected chapter')
initial.reader.pclts=nil;initial.reader.token=nil
Content.ensure_reader_state(client,book)
expect(book.pclts==nil and book.token==nil,'omitted fields retained old session values');fixture()
book.reader_url='https://example.invalid/stale';Content.fetch_catalog(client,book)
expect(requests[#requests].options.referer==root and requests[#requests].options.sensitive
    and requests[#requests].body.bookIds[1]=='900001','catalog retained foreign referer or changed book identity')
initial.reader.bookInfo.bookId='900002'
local old_offset=book.chapter_offset
local rejected_ok,rejected_error=pcall(Content.ensure_reader_state,client,book)
expect(not rejected_ok and rejected_error=='The reading page could not be verified for this book. Refresh the book details and try again.',
    'mismatched download context did not show fixed user guidance')
expect(book.psvts==nil and book.pclts==nil and book.token==nil and book.chapter_offset==old_offset
    and book.cached_file=='/synthetic/kept.epub','rejected response left session or changed current book');fixture()
client.get_text=function() error('sensitive_http_unavailable',0) end
book.psvts='old';book.pclts='old';book.token='old'
local ok,err=pcall(Content.ensure_reader_state,client,book)
expect(not ok and err=='Could not load this book’s reading page. Check your connection and login, then try again.' and book.psvts==nil and book.pclts==nil and book.token==nil,'network failure retained a usable old session')
local old_chapters={{chapterUid=7}}
book.chapters=old_chapters
client.post_json=function() error('private catalog body') end
ok,err=pcall(Content.fetch_catalog,client,book)
expect(not ok and err=='Could not load this book’s chapter list. Check your connection and login, then try again.'
    and book.chapters==old_chapters,'catalog failure exposed raw error or replaced cached chapters')
print('PASS: download Reader context ('..checks..' checks)')
