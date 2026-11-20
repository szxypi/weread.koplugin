package.path='./?.lua;'..package.path
local Notes=require('weread.lib.notes_export')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fails(reason,task)
    local ok,err=pcall(task);expect(not ok and err=='notes_export/'..reason,reason..' did not fail closed')
end
local input={book={title='合成书籍 <script>',authors='作者'},now=0,annotations={
    {text='Bookmark only',page='/secret/bookmark'},
    {drawer='lighten',text='第一行\n第二行 [link](https://example.invalid) <img src=x>',note='想法\n![remote](secret)',
        chapter='章节 *一*',pageno=12,page='/secret/xpointer',pos0={x=123},datetime='2026-11-09 12:00:00',token='discard'},
    {drawer='underscore',text='',note='Only note',pageref='xii',pageno=13},
    {drawer='lighten',text='   ',note='\n'},
}}
local function export(format,source)
    local chunks,values={},{}
    local result=Notes.write(source or input,format,function(value)
        values[#values+1]=value;return '{}'
    end,function(bytes) chunks[#chunks+1]=bytes;return true end)
    return table.concat(chunks),result,values
end
local json,result,values=export('json')
expect(result.count==2 and result.bytes==#json,'annotation filtering or byte count wrong')
expect(json=='{"schema":1,"source":"KOReader","book":{},"annotations":[{},{}]}\n','JSON stream shape wrong')
expect(values[1].title==input.book.title and values[1].author=='作者' and values[1].exported_at=='1970-01-01T00:00:00Z','book metadata changed')
expect(values[2].text==input.annotations[2].text and values[2].note==input.annotations[2].note and values[2].page=='12','quote/note/recorded page changed')
expect(values[2].token==nil and values[2].pos0==nil and values[2].page~='/secret/xpointer' and values[2].pageno==nil,'native/private fields leaked')
expect(values[3].page=='xii' and values[3].note=='Only note','page label or note-only highlight lost')
local md,summary=export('markdown')
expect(summary.count==2 and #md==summary.bytes and md:find('> 第一行\n> 第二行',1,true),'multiline quote was not quoted')
expect(not md:find('<script>',1,true) and not md:find('<img',1,true) and not md:find('[link](',1,true)
    and not md:find('![remote](',1,true) and md:find('&lt;script&gt;',1,true),'Markdown activated raw HTML or remote link')
expect(md:find('Note:\n\n> 想法',1,true) and md:find('Recorded page: xii',1,true),'Markdown note/page absent')
expect(Notes.item({drawer='lighten',note='yes',page='/pointer'}).page==nil,'native xpointer exported as page')
expect(Notes.item({drawer='lighten',text='a\r\nb\rc'}).text=='a\nb\nc','line endings not normalized')
for _,bad in ipairs({'\255',string.char(0),'bad\1',string.rep('a',Notes.MAX_TEXT_BYTES+1)}) do
    fails('invalid_text',function() Notes.item({drawer='lighten',text=bad}) end)
end
fails('invalid_text',function() Notes.book({authors={}}) end)
fails('no_notes',function() export('json',{annotations={{text='bookmark'}},book={}}) end)
fails('invalid_format',function() export('html') end)
fails('write_failed',function() Notes.write(input,'markdown',nil,function() return false end) end)
local old_items,old_bytes=Notes.MAX_ITEMS,Notes.MAX_OUTPUT_BYTES
Notes.MAX_ITEMS=1
fails('too_many',function() export('json') end)
Notes.MAX_ITEMS=old_items;Notes.MAX_OUTPUT_BYTES=8
fails('too_large',function() export('markdown') end)
Notes.MAX_OUTPUT_BYTES=old_bytes
expect(Notes.filename('../恶意/名称:book?')=='_恶意_名称_book_', 'filename path punctuation not removed')
expect(#Notes.filename(string.rep('中',50))==96,'UTF-8 filename was split or not bounded')
expect(Notes.book({},'Fallback',0).title=='Fallback','missing title fallback lost')
expect(Notes.directory({data_dir='/data/'})=='/data/exports/notes','export directory wrong')
expect(Notes.is_export_path({data_dir='/data'},'/data/exports/notes/book.md')
    and not Notes.is_export_path({data_dir='/data'},'/data/exports/notebook.md'),'path boundary unsafe')
expect(not Notes.directory({data_dir='/bad\npath'}),'control in path accepted')
print('PASS: local notes model ('..checks..' checks)')
