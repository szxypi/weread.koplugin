package.path='./?.lua;'..package.path
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local live=true;local scope={vid='123',epoch=1};local wanted={book_id='42',chapter_uid='38',chapter_idx=3}
local entry={book_id='42',chapter_uid='38',chapter_idx=3,book_version=7,file_id=string.rep('a',64)}
local native,web={},{};local clock=100
package.preload['weread.lib.native_read_access']=function() return {matches=function() return live end} end
package.preload['weread.lib.source_currentness']=function() return {matches=function() return live end} end
package.preload['weread.lib.native_direct_cloud']=function() return {valid_target=function(v) return v==wanted end} end
package.preload['weread.lib.native_direct_cache']=function() return {valid_entry=function(e,id,vid) return e==entry and id=='42' and vid=='123' end} end
package.preload['weread.lib.native_direct_path']=function() return {contains=function(_,path) return path=='/target' end} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function(doc) return doc.identity end} end
local H=require('weread.lib.native_direct_cloud_handoff')
local function fixture()
    live=true;clock=100
    local settings={auth_scope_matches=function(_,value) return value==scope and live end}
    local olddoc={file='/old'};local ctx={scope=scope,session=1,document=olddoc,native=native,web=web,is_current=function() return live end}
    local host={settings=settings,_reader_session_gen=1,_native_direct_position=ctx}
    local newdoc={file='/target',identity={book_id='42',file_id=entry.file_id,book_version=7}}
    local next_host={settings=settings,ui={document=newdoc}}
    local reader={document=newdoc,weread=next_host};local received=0
    local resolved={entry=entry,target=wanted,path='/target'}
    local handoff=H.prepare(host,ctx,resolved,function(h,e,t,n,w)
        assert(h==next_host and e==entry and t==wanted and n==native and w==web);received=received+1;return true
    end,function() return clock end)
    assert(handoff);return host,reader,handoff,function() return received end
end
local host,reader,handoff,count=fixture();host._reader_session_gen=2
expect(handoff(reader) and count()==1,'valid transfer was lost')
expect(not handoff(reader) and count()==1,'handoff replayed')
host,reader,handoff,count=fixture();expect(host._reader_session_gen==1 and not handoff(reader) and count()==0,'old reader session accepted')
host,reader,handoff,count=fixture();host._reader_session_gen=2;live=false
expect(not handoff(reader) and count()==0,'changed account accepted')
host,reader,handoff,count=fixture();host._reader_session_gen=2;reader.document.identity.file_id=string.rep('b',64)
expect(not handoff(reader) and count()==0,'different file identity accepted')
host,reader,handoff,count=fixture();host._reader_session_gen=2;clock=281
expect(not handoff(reader) and count()==0,'expired handoff accepted')
host,reader,handoff,count=fixture();host._reader_session_gen=2;reader.document.file='/other'
expect(not handoff(reader) and count()==0,'different file accepted')
print('PASS: native cloud handoff is one-use and account/file bound ('..checks..' checks)')
