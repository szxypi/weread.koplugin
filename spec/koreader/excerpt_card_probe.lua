-- Synthetic content only; run inside a packaged KOReader profile.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local RenderText=require('ui/rendertext')
local original=RenderText.renderUtf8Text
local Card=require('weread.lib.excerpt_card.init')
assert(RenderText.renderUtf8Text==original,'loading changed the global renderer')
assert(#Card.TEMPLATES==6 and #Card.COLORS==10)
local evidence=assert(os.getenv('WEREAD_EXCERPT_EVIDENCE'))
local count=0
for i=1,#Card.TEMPLATES do
    for color=1,10 do
        local image,size=Card.renderBB{
            text='这是合成书摘。\nA synthetic excerpt with punctuation.',
            book_title='测试书名',book_author='测试作者',date_str=1700000000,
            template_idx=i,color_idx=color,background_idx=color,
        }
        assert(image and size.w==1125 and size.h>0 and size.h<12000)
        assert(RenderText.renderUtf8Text==original,'render left global renderer patched')
        image:writePNG(evidence..'/excerpt-'..i..'-'..color..'.png');image:free()
        count=count+1
    end
end
local with_rgb=require('weread.lib.excerpt_card.rgb32')
assert(not pcall(with_rgb,function() error('synthetic error') end))
assert(RenderText.renderUtf8Text==original,'failed render left global renderer patched')
local image,reason=Card.renderBB{text='   '}
assert(not image and reason=='empty text' and RenderText.renderUtf8Text==original)
assert(not Card.renderBB{text=string.rep('a',4097)},'oversized excerpt was accepted')
assert(not Card.renderBB{text='\255'},'invalid UTF-8 was accepted')
assert(not Card.renderBB{text='valid',book_title='\0'},'invalid title was accepted')
local long, long_size=Card.renderBB{text=string.rep('合成书摘的一段文字。',70),template_idx=1}
assert(long and long_size.truncated==true,'long selection was not flagged as truncated');long:free()
local opts={text='保存测试',book_title='合成书名',book_author='作者'}
local first=assert(Card.save(opts,evidence));local second=assert(Card.save(opts,evidence))
assert(first~=second,'saving overwrote an existing card')
for _,path in ipairs({first,second}) do
    local f=assert(io.open(path,'rb'));assert(f:read(8)=='\137PNG\r\n\26\n');f:close()
    local ok,decoded=require('ffi/png').decodeFromFile(path,4)
    assert(ok and decoded.width==1125 and decoded.height>0 and decoded.data,'saved PNG could not be decoded')
    require('ffi').C.free(decoded.data)
end
assert(not Card.save(opts,evidence..'/not-a-directory\0invalid'),'invalid output path was accepted')
assert(RenderText.renderUtf8Text==original,'saving left global renderer patched')
print('\nWEREAD_EXCERPT='..require('json').encode({result='PASS',images=count}))
os.exit(0)
