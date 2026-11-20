-- Run after the full core smoke, in a new process with its isolated KO_HOME.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
local evidence=assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Settings=require('weread.lib.settings')
local Identity=require('weread.lib.mp_cache_identity')
local Versions=require('weread.lib.mp_cache_versions')
local Doc=require('docsettings')
local settings=Settings:new()
assert(settings.mock_endpoint and settings.data_dir:match('/weread%-mock$'),'reopen requires a synthetic profile')
local modes={}
for index,location in ipairs({'doc','dir','hash'}) do
    G_reader_settings:saveSetting('document_metadata_folder',location)
    Doc.setIsHashLocationEnabled(location=='hash')
    local book=assert(settings:get('books',{})['MP_WXS_'..(900071+index)])
    local key=assert(Identity.key(book,{reviewId='metadata-fixture'}))
    local entries=assert(Versions.list(book.cache_dir,key))
    assert(#entries==2,'reopen lost retained revisions or revived a deleted body')
    for _,entry in ipairs(entries) do
        local data=Doc:open(entry.path)
        local _,found=Doc:findSidecarFile(entry.path)
        local expected=entry.current and '再次下载独立划线' or '新版划线'
        assert(found==location and data:readSetting('last_xpointer')=='/body/p[1]/text().10'
            and data:readSetting('annotations')[1].text==expected,'fresh process mixed or lost revision metadata')
    end
    assert(book.progress==.45 and book.pending_upload_position.offset==23,'persisted reading state changed')
    modes[#modes+1]={location=location,retained_versions=2,fresh_process_notes_and_position=true,progress_pending_preserved=true}
end
local file=assert(io.open(evidence..'/mp-metadata-reopen.json','wb'))
assert(file:write(require('json').encode({result='PASS',synthetic_only=true,fresh_process=true,modes=modes,account_reads=0,account_data_writes=0})))
file:close()
print('PASS: fresh-process doc/dir/hash metadata -> distinct retained revision notes and positions, persisted progress/intent')
