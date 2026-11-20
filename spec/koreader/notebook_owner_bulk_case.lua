-- Real account reads are limited by the caller; all note data stays in tmpfs.
return function(plugin,owner,mode,ids,counters,report,home)
    local UI=require('ui/uimanager');local socket=require('socket');local json=require('json')
    local cache=require('weread.lib.my_cloud_marks_store');local crypto=require('weread.lib.crypto')
    local function pump(predicate,seconds)
        local deadline=socket.gettime()+seconds
        while not predicate() do
            assert(socket.gettime()<deadline,'notebook bulk deadline')
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        end
    end
    local function item(label)
        for _,row in ipairs(owner.menu.item_table) do
            if row.text==require('weread.lib.i18n').tr(label) then return row end
        end
        error('notebook bulk menu missing')
    end
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~='table' then return a==b end
        for key,value in pairs(a) do if key~='fetched_at' and not same(value,b[key]) then return false end end
        for key in pairs(b) do if key~='fetched_at' and a[key]==nil then return false end end
        return true
    end
    local function hashes()
        local db=assert(plugin.library_db:openRead());local result=json.decode('[]')
        for _,id in ipairs(ids) do
            local pair=json.decode('[]')
            for _,variant in ipairs({'marks','thoughts'}) do
                local value=assert(cache:new(plugin.library_db,plugin.client,variant=='thoughts' and 'thoughts' or nil):read(id))
                assert(value.book_id==id)
                local table_name=variant=='thoughts' and 'my_cloud_thoughts' or 'my_cloud_marks'
                local stmt=db:prepare('SELECT payload FROM '..table_name..' WHERE book_id=?')
                local row=stmt:bind(id):step();stmt:close()
                assert(row and type(row[1])=='string' and #row[1]<=cache.MAX_PAYLOAD)
                pair[#pair+1]=crypto.sha256_hex(row[1])
            end
            result[#result+1]=pair
        end
        db:close();return json.encode(result)
    end
    local filename=home..'/notebook-bulk-digests.json'
    if mode=='live' then
        local transient,renewal=plugin.showTransientInfo,plugin.native_renewal
        plugin.showTransientInfo=function() end;plugin.native_renewal=nil
        owner.menu:onMenuSelect(item('Save all notebook notes for offline use'))
        pump(function() return owner.bulk_context~=nil end,10)
        local job=assert(owner.bulk_context);report.menu_started=true
        assert(#job.ids==#ids and job.skipped==report.skipped and job.dialog.progress_max==#ids*2)
        for index,id in ipairs(ids) do assert(job.ids[index]==id) end
        pump(function() return not owner.bulk_context end,480)
        report.saved=job.done
        assert(job.done==#ids*2 and counters[1]==0)
        local before=tonumber(counters[2])
        owner.menu:onMenuSelect(item('Save only missing notebook notes'))
        pump(function() return owner.bulk_context~=nil end,10);job=owner.bulk_context
        pump(function() return not owner.bulk_context end,120)
        assert(job.done==0 and job.saved==0 and job.already==#ids*2 and counters[2]==before)
        local first_id=ids[1]
        local old=assert(cache:new(plugin.library_db,plugin.client):read(first_id))
        local db=assert(plugin.library_db:open());db:exec('BEGIN IMMEDIATE')
        local stmt=db:prepare('DELETE FROM my_cloud_marks WHERE book_id=?')
        stmt:bind(first_id):step();stmt:close();db:exec('COMMIT');db:close()
        counters[3]=1
        owner.menu:onMenuSelect(item('Save only missing notebook notes'))
        pump(function() return owner.bulk_context~=nil end,10);job=owner.bulk_context
        pump(function() return not owner.bulk_context end,120)
        local restored=assert(cache:new(plugin.library_db,plugin.client):read(first_id))
        assert(job.done==1 and job.saved==1 and job.already==#ids*2-1
            and counters[2]==before+1 and counters[4]==1 and counters[1]==0 and same(old,restored))
        report.resume_checked=true;report.resume_requests=1;report.requests=tonumber(counters[2])
        local digest=hashes();local file=assert(io.open(filename,'wb'))
        assert(file:write(digest) and file:close());report.cache_verified=true
        plugin.showTransientInfo,plugin.native_renewal=transient,renewal
    else
        local file=assert(io.open(filename,'rb'));local digest=file:read(65537);file:close()
        assert(#digest<=65536 and digest==hashes() and counters[2]==0 and counters[1]==0)
        report.saved=#ids*2;report.cache_verified=true
    end
end
