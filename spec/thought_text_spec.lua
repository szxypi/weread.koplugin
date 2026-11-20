package.path='./?.lua;'..package.path
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local emoji={hash='emoji'}
local present=true
local factory={findEmojiFont=function() return present and '/plugin/emoji.ttf' or nil end,
    _getFallbackFace=function(_self,path,size) expect(size==40,'DPI-scaled size changed');return path and emoji end}
package.preload['weread.ui.thought_popup.face_factory']=function() return factory end
local latin,cjk={hash='latin'},{hash='cjk'}
local base={hash='base',size=40,orig_size=20,ftsize={getEmboldenHalfStrength=function() return 3 end},fallbacks={}}
base.getFallbackFont=function(n) return n==0 and base or ({latin,cjk})[n] or false end
local original=base.getFallbackFont
local Text=require('weread.ui.thought_text')
local face=Text.face(base)
expect(face~=base and face.ftsize==base.ftsize and face.size==40 and face.orig_size==20,'primary metrics replaced')
expect(face.getFallbackFont()==face and face.getFallbackFont(0)==face,'shaper received the shared primary face')
expect(face.getFallbackFont(3)==emoji and face.getFallbackFont(1)==latin and face.getFallbackFont(2)==cjk,
    'existing CJK/Latin fallback priority changed')
expect(not face.getFallbackFont(4) and not face.getFallbackFont(15),'emoji is not the last fallback')
expect(Text.face(base)==face and Text.face(face)==face,'face wrapping accumulated fallbacks')
expect(base.getFallbackFont==original and next(base.fallbacks)==nil and not base.embolden_half_strength,
    'shared font face changed')
expect(face.embolden_half_strength==3,'shaper bold metrics absent')
local many={size=40,ftsize=base.ftsize,getFallbackFont=function(n) return n>=1 and n<=15 and cjk or false end}
local capped=Text.face(many)
expect(capped.getFallbackFont(15)==cjk and not capped.getFallbackFont(16),'existing full chain truncated or over capacity')
for _i,n in ipairs({-1,.5,16,'1'}) do expect(not face.getFallbackFont(n),'invalid fallback index accepted') end
present=false
local missing={size=40,ftsize=base.ftsize,getFallbackFont=original}
expect(Text.face(missing)==missing and Text.face(nil)==nil and Text.face({}).ftsize==nil,'missing font broke native text')
present=true
package.preload['ui/font']=function() return {getFace=function() return base end} end
package.preload['ui/widget/inputdialog']=function() return {new=function(_self,options) return options end} end
expect(Text.input{input='😀'}.input_face==face,'input did not receive scoped face')
local frees,inits,resets=0,0,0
local Parent={}
function Parent:extend(child) return setmetatable(child,{__index=self}) end
function Parent:new(options) setmetatable(options,{__index=self});options:init();return options end
function Parent:init()
    self.is_txt=not self.html
    self.box_widget={use_xtext=not self.legacy,face=base,charlist='old shaper',
        free=function() frees=frees+1 end,init=function(box) inits=inits+1;expect(box.charlist==nil,'freed shaper reused') end}
    self.scroll_widget={resetScroll=function() resets=resets+1 end}
end
package.preload['ui/widget/textviewer']=function() return Parent end
local viewer=Text.viewer{text='😀'}
expect(viewer.box_widget.face==face and viewer.scroll_widget.face==face and frees==1 and inits==1 and resets==1,
    'viewer was not reshaped and scroll state refreshed')
viewer:init(true)
expect(frees==2 and inits==2 and resets==2,'viewer font change lost fallback')
Text.viewer{html=true};Text.viewer{legacy=true}
expect(frees==2 and inits==2,'unsupported renderer was modified')
local bare={new=function(_self,options) return options end}
package.preload['ui/widget/menu']=function() return bare end
expect(Text.menu{title='Legacy'}.title=='Legacy','legacy menu fallback failed')
package.loaded['ui/widget/menu']=nil
package.preload['ui/size']=function() return {span={horizontal_default=10}} end
local menu_parent={}
function menu_parent:extend(child) return setmetatable(child,{__index=self}) end
function menu_parent:new(options) setmetatable(options,{__index=self});options:updateItems();return options end
function menu_parent:updateItems() self.updates=(self.updates or 0)+1 end
package.preload['ui/widget/menu']=function() return menu_parent end
local menu_resets=0
local function row_widget(fail_new,has_missing)
    local text={text='sample',face=base,use_xtext=true,_shape_start=1,_shape_end=1}
    function text:free() self._xtext=nil end
    function text:updateSize()
        if fail_new and self.face==face then error('unavailable font') end
        self._xtext={shapeLine=function() return {{glyph=has_missing and self.face==base and 0 or 7,font_num=0}} end}
    end
    text:updateSize()
    local mandatory={getWidth=function() return 20 end,use_xtext=false}
    local group={{width=0},text,resetLayout=function() menu_resets=menu_resets+1 end}
    local row={content_width=300,text='sample',mandatory='book',_underline_container={{{[2]={group},[3]={mandatory}}}}}
    return row,text
end
local row,fake_text=row_widget(false,true)
local group={row,resetLayout=function() menu_resets=menu_resets+1 end}
local menu=Text.menu{item_group=group}
expect(fake_text.face==face and fake_text.max_width==270 and menu_resets==2,'scoped menu did not rebuild missing text within its row')
menu:updateItems();expect(menu.updates==2 and menu_resets==2,'menu reused or duplicated its fallback')
row,fake_text=row_widget(true,true);group={row,resetLayout=function() menu_resets=menu_resets+1 end}
Text.menu{item_group=group}
expect(fake_text.face==base and fake_text.max_width==nil and fake_text._xtext~=nil,'failed font rebuild did not restore native text')
row,fake_text=row_widget(false,false);group={row,resetLayout=function() menu_resets=menu_resets+1 end}
Text.menu{item_group=group}
expect(fake_text.face==base and fake_text.max_width==nil,'ordinary menu row was modified')
expect(Text.menu{item_group={{text='unknown layout'}}}~=nil,'unknown menu layout did not fall back')
print('thought_text_spec: '..checks..' checks')
