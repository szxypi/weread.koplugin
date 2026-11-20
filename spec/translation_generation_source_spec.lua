package.path='./?.lua;'..package.path
local Crypto=require('weread.lib.crypto')
local raw='<html><body><p>'..string.rep('A native source paragraph with enough real text. ',5)..'</p></body></html>'
local translated=raw:gsub('</p>', '</p><p class="wr-translation">已经有译文</p>')
local world={};local input={book_id='456',chapter_uid='7',path='/synthetic.epub',metadata='metadata',file_id='file-one'}
local function reset()
    world={valid=true,local_hash=Crypto.sha256_hex(raw),network_raw=raw,native_calls=0,fetches=0,catalogs=0,archives=0,title='Chapter One'}
end
reset()
package.loaded['weread.lib.position_source']={MAX_BYTES=2097152,MAX_META_BYTES=2048,MAX_RENDERED_BYTES=2097152,
    meta_path=function() return 'meta' end,raw_path=function() return 'raw' end,
    decode_metadata=function(value) if value~='metadata' then return nil end
        return {chapter_uid='7',format='web_xhtml',raw_sha256=world.local_hash,render_path='render'} end,
    verify_snapshot=function(value)
        if value.raw~='local' or value.rendered~='rendered' or value.metadata~='metadata' then return nil end
        return {raw_sha256=world.local_hash,raw=world.local_raw or raw}
    end}
package.loaded['weread.lib.book_file_identity']={PATH='identity',MAX_BYTES=2048,
    decode=function(value) if value~='identity' then return nil end;return {book_id='456',file_id='file-one',book_version=7} end}
package.loaded['weread.lib.source_archive']={read=function(_path,wanted)
    world.archives=world.archives+1
    if world.changed_local and world.archives>2 then return nil end
    if wanted.identity then return {identity='identity',meta='metadata'} end
    return {raw='local',render='rendered'}
end}
package.loaded['weread.lib.translation_generation_access']={inspect=function()
    world.native_calls=world.native_calls+1
    return {book_id='456',uid=7,version=world.version or 7,catalog_sha256=world.changed_native and world.native_calls>1 and 'changed' or 'stable',
        translate_version=0,title=world.title}
end}
package.loaded['weread.lib.native_read_access']={matches=function() return world.valid end}
package.loaded['weread.lib.translation_fetch']={client=function(client) return client end}
package.loaded['weread.lib.content']={ensure_reader_state=function() end,
    fetch_catalog=function()
        world.catalogs=world.catalogs+1
        return {{chapterUid=7,title=world.changed_catalog and world.catalogs>1 and 'Different' or 'Chapter One'}},world.web_version or 7
    end,
    fetch_chapter_xhtml=function()
        world.fetches=world.fetches+1
        local value=world.changed_remote and world.fetches>1 and raw..' ' or world.network_raw
        return value,{format='web_xhtml',book_id='456',chapter_uid='7',raw=value,raw_sha256=Crypto.sha256_hex(value)}
    end}
local Source=require('weread.lib.translation_generation_source')
local function inspect() return Source.inspect({}, {}, {}, input, {is_current=function() return world.valid end}) end
local result,reason=inspect()
assert(result and result.kind=='source_verified' and result.source_sha256==world.local_hash and world.native_calls==2
    and world.fetches==2 and world.archives==4 and world.catalogs==2,reason or 'incomplete preflight')
reset();world.web_version=0;assert(inspect().kind=='source_verified','unknown web version rejected exact source proof')
for _,scenario in ipairs({'changed_remote','changed_local','changed_native','changed_catalog'}) do
    reset();world[scenario]=true;assert(not inspect(),'changed evidence passed: '..scenario)
end
reset();world.network_raw=translated
assert(inspect().kind=='available','existing cloud translation was not recognized')
reset();world.network_raw='<html><body><script>'..string.rep('fake ',100)..'</script><p>short</p></body></html>'
local _,missing=inspect();assert(missing=='missing_original','script was counted as original text')
reset();world.network_raw='<html><body><p class="wr-translation">'..string.rep('译文',100)..'</p></body></html>'
local _,without_original=inspect();assert(without_original=='source_changed','translation without the original was accepted')
reset();world.network_raw=translated:gsub('native source','altered source')
local _,altered_original=inspect();assert(altered_original=='source_changed','translated content with altered original was accepted')
reset();world.network_raw=raw:gsub('</p>', '</p><p class=wr-translation>'..string.rep('translated ',20)..'</p>')
local _,ambiguous=inspect();assert(ambiguous=='unavailable','unknown translated class syntax was admitted as original')
reset();world.title='Copyright Page';local _,structural=inspect();assert(structural=='structural' and world.fetches==0,'copyright page admitted')
reset();world.valid=false;local _,stale=inspect();assert(stale=='session_changed' and world.native_calls==0,'stale account issued reads')
reset();world.local_hash=string.rep('b',64);local _,different=inspect();assert(different=='source_changed','different local original admitted')
reset();world.version=8;local _,version=inspect();assert(version=='version' and world.fetches==0,'changed book version admitted')
print('PASS: native translation source and account binding')
