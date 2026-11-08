package.path='./?.lua;'..package.path
local Context=require('weread.lib.source_context')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function characters(text)
    local chars={};for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars+1]=char end;return chars
end
local function fixture(text,offset)
    local chars=characters(text)
    local root='/body/DocFragment[1]'
    local function xp(n) return root..'/body/p/text().'..n end
    local function at(point) return assert(tonumber(point:match('%.(%d+)$'))) end
    local book,chapter={book_id='synthetic',bookVersion=7},{chapterUid=11}
    local path='OEBPS/text/chapter.xhtml'
    local raw='<html><body><p>original exact source text</p></body></html>'
    local source=assert(Source.capture(book,chapter,raw,'web_xhtml'))
    local identity=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(text))
    local metadata=assert(Source.bind(source,Identity.decode(identity),path,Crypto.sha256_hex(text)))
    local reads,cleared={},0
    local doc={file='/test.epub'}
    function doc:getCurrentPage() return 1 end
    function doc:getCurrentPos() return 0 end
    function doc:getXPointer() return xp(offset) end
    function doc:getPageXPointer() return xp(offset) end
    function doc:getNormalizedXPointer(point) return point end
    function doc:getHTMLFromXPointers() return '<body><DocFragment Source="'..path..'"><body/></DocFragment></body>' end
    function doc:getDocumentFileContent(name)
        reads[name]=(reads[name] or 0)+1
        if name==Identity.PATH then return identity end
        if name==Source.path_meta_path(path) then return metadata end
        error('UI attempted to read body')
    end
    function doc:getPrevVisibleChar(point)
        return at(point)>0 and xp(at(point)-1) or '/body/DocFragment[0]/body/p/text().4'
    end
    function doc:getNextVisibleChar(point)
        return at(point)<#chars-1 and xp(at(point)+1) or '/body/DocFragment[2]/body/p/text().0'
    end
    function doc:getTextFromXPointers(first,last)
        -- Native equal-range extraction is deliberately unsuitable for an
        -- empty prefix. The adapter must not call it in that case.
        if first==last then return 'WRONG' end
        local out={}
        for n=at(first)+1,math.min(at(last),#chars) do out[#out+1]=chars[n] end
        return table.concat(out)
    end
    function doc:clearSelection() cleared=cleared+1 end
    return doc,xp,reads,function() return cleared end
end
local text='ABCDE😀 &中文[36]FGHIJKLMNOPQRSTUVWXYZ'
local doc,_,reads,cleared=fixture(text,0)
local loc=assert(Context.location(doc,'page'))
local frame=Context.capture(doc,'synthetic',loc)
expect(frame.text=='ABCDE😀&中文[36]FGHIJKLMNOPQRSTUVWXYZ' and frame.point_offset==0,'first character/prefix was lost')
expect(frame.file==doc.file and frame.chapter_uid=='11','native resource identity lost')
local invalid=Context.capture(doc,'synthetic',{xpointer='/body/DocFragment[1]/body/p/text().9999'})
expect(invalid.error=='context_unavailable','out-of-bounds native bookmark became a source point')
expect(reads[Identity.PATH]==1 and reads[Source.path_meta_path(frame.render_path)]==2,'large members read on UI loop')
expect(cleared()>0,'native selection left behind')
local last_doc=fixture(text,#characters(text)-1)
frame=Context.capture(last_doc,'synthetic',assert(Context.location(last_doc,'page')))
expect(frame.text:sub(-1)=='Z' and frame.point_offset==#characters(frame.text)-1,'final visible scalar excluded from context')
local located=Context.location(doc,'scroll')
expect(Context.same_location(located,Context.location(doc,'scroll')),'identical frame changed')
expect(not Context.same_location(located,loc),'view mode did not invalidate frame')
expect(not Context.same_location(located,{page=2,pos=0,xpointer=located.xpointer,view_mode='scroll'}),'page change ignored')
local image_location={xpointer='/body/DocFragment[1]/body/p/img.0'}
expect(Context.capture(doc,'synthetic',image_location).error=='no_visible_text','image was treated as text')
local top,top_xp=fixture(text,0)
local structural='/body/DocFragment[1]/body.0'
local native_next=top.getNextVisibleChar
top.getNextVisibleChar=function(self,point) return point==structural and top_xp(0) or native_next(self,point) end
top.getPosFromXPointer=function() return 0 end
local first=Context.capture(top,'synthetic',{xpointer=structural,view_mode='scroll'},{viewport_height=600})
expect(first.point_offset==0 and first.chapter_uid=='11','scroll structural boundary did not resolve to visible first text')
top.getPosFromXPointer=function() return 600 end
expect(Context.capture(top,'synthetic',{xpointer=structural,view_mode='scroll'},{viewport_height=600}).error=='no_visible_text',
    'structural boundary selected text below the viewport')
local long=string.rep('abcdefghijklm',60)
local long_doc=fixture(long,300)
local current=true
local cancelled=Context.capture(long_doc,'synthetic',assert(Context.location(long_doc,'page')),
    {is_current=function() return current end,yield=function() current=false end})
expect(cancelled.error=='cancelled','cancelled native context committed')
doc.getCurrentPos=function() return math.huge end
expect(not Context.location(doc,'page'),'invalid native position accepted')
doc.getCurrentPos=function() return 0 end
doc.getTextFromXPointers=function() return string.rep('x',Context.MAX_CONTEXT_BYTES+1) end
expect(Context.capture(doc,'synthetic',loc).error=='context_unavailable','oversized context accepted')
print(('source_context_spec: %d checks'):format(checks))
