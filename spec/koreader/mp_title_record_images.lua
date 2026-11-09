return function(entry,reader)
    local Crypto=require('weread.lib.crypto')
    local Assets=require('weread.lib.mp_record_assets')
    local UIManager=require('ui/uimanager')
    local function read(path)
        local file=assert(io.open(path,'rb'));local raw=file:read('*a');file:close();return raw
    end
    if not entry.exported then
        local html=read(entry.path)
        local body=assert(html:match('<body>.*</body>'))
        assert(Crypto.sha256_hex(Assets.rewrite(body,function() return 'IMAGE' end))==entry.canonical_body_sha256,
            'relocation changed DOM/text outside image source attributes')
        local source=assert(html:match('src="([^"<>]+/images/img%-0001%.png)"'))
        local image=entry.path:match('^(.*)/[^/]+$')..'/'..source
        assert(Crypto.sha256_hex(read(image))==entry.source_image_sha256,'relocated bitmap bytes changed')
    end
    assert(Crypto.sha256_hex(read(entry.source_html))==entry.source_html_sha256,'original title HTML changed')
    assert(Crypto.sha256_hex(read(entry.source_image))==entry.source_image_sha256,'original title bitmap changed')
    reader.rolling:onGotoPage(1);UIManager:forceRePaint()
    local screen=require('device').screen
    local found=false
    for y=0,screen:getHeight()-1,12 do
        for x=0,screen:getWidth()-1,12 do
            local bitmap=reader.document:getImageFromPosition({x=x,y=y},false,false)
            if bitmap and type(bitmap)~='function' then
                if bitmap:getWidth()==48 and bitmap:getHeight()==48 then
                    assert(bitmap:getPixel(3,3):getColor8().a==0 and bitmap:getPixel(44,3):getColor8().a==255,
                        'CRE resolved another bitmap after relocation')
                    found=true
                end
                bitmap:free()
                if found then break end
            end
        end
        if found then break end
    end
    assert(found,'CRE could not decode the relocated image from its HTML position')
    if entry.preview_png then screen:shot(entry.preview_png) end
    reader.rolling:onGotoXPointer(entry.xpointer);UIManager:forceRePaint()
    assert(reader.document:isXPointerInCurrentPage(entry.xpointer),'bitmap check did not restore record position')
end
