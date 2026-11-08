-- One-use, in-memory transfer across ReaderUI:switchDocument. No persistence.
local Cloud=require('weread.lib.source_cloud')
local Identity=require('weread.lib.book_file_identity')
local M={}
function M.prepare(host,job,file,identity,remote,on_open,now)
    remote=Cloud.remote(remote)
    if type(job)~='table' or type(job.session)~='number' or not remote or remote.book_id~=job.book_id
        or type(file)~='string' or file=='' or #file>4096 or file:find('[%z%c]')
        or type(identity)~='table' or type(identity.file_id)~='string' or #identity.file_id~=64
        or identity.book_id~=job.book_id or type(on_open)~='function' then return nil end
    local sync=host.progress_sync
    if not sync or host.cloud_source_request~=job or host._reader_session_gen~=job.session
        or sync.navigation_generation~=job.navigation_generation or not Cloud.matches(host.settings,job.access) then return nil end
    now=now or os.time
    local started=now()
    local generation,account_generation=sync.generation,sync.account_generation
    if type(generation)~='number' then return nil end
    local used=false
    return function(reader)
        if used then return false end
        used=true
        local age=now()-started
        local next_host=reader and reader.weread
        local next_sync=next_host and next_host.progress_sync
        local document=next_host and next_host.ui and next_host.ui.document
        if age<0 or age>120 or host._reader_session_gen~=job.session+1
            or sync.generation~=generation+1 or sync.account_generation~=account_generation
            or sync.navigation_generation~=job.navigation_generation or not Cloud.matches(host.settings,job.access)
            or not next_host or next_host==host or not next_sync or next_sync==sync or next_sync.navigation_generation~=0
            or document~=reader.document or not document or document==job.document or document.file~=file
            or tostring(next_host:detectWeReadBook() or '')~=job.book_id or not Cloud.matches(next_host.settings,job.access)
            or Identity.read_document(document,job.book_id).file_id~=identity.file_id then return false end
        return on_open(next_host,remote,identity.file_id,job.access)==true
    end
end
return M
