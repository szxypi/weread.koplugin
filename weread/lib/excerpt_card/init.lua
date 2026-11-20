--[[--
书摘卡片渲染基座：离线合成书摘分享卡片，输出 RGB32
BlitBuffer / PNG。纯本地能力（生成图片不联网）。

本模块提供离屏图片合成能力；书摘弹窗 UI、图片保存流程、
图床二维码分享等由调用方自行实现，本模块只提供合成原语与模板/配色数据。

六套模板：
  classic  （经典：页眉书名+日期，正文两端对齐，文后「/ 书名」+作者，页脚发丝线）
  inkwhite （墨白：竖排书名/作者/日期 + 正文）
  notebook / stillness / ornate / calendar 其余四套模板。
配色 10 色（另有渐变/图底，插件用纯色近似）。

渲染：
  BlitBuffer（RGB32）+ RenderText 离屏绘制，写 PNG 落盘。
  文字用 RenderText:renderUtf8Text（colorblitFrom 染色），
  不依赖 Screen:isColorEnabled，灰度 e-ink 上导出的卡片也是彩色 PNG。
  不上屏，预览由调用方用 ImageWidget 显示（file=path）。

目录：
  config.lua    — 常量（画布 / 倍率 / 背景图名称 / 日历文案）
  templates.lua — 模板 / 配色 / 背景图定义（纯数据）
  device.lua    — 页脚品牌文案（按设备标志/型号识别）
  fonts.lua     — CRE 族名 → 字体文件解析 / safeGetFace
  rgb32.lua     — RenderText:renderUtf8Text RGB32 染色补丁（加载即生效）
  assets.lua    — 墨白线条图 / 静影背景图（只使用打包资产）
  runes.lua     — 切字辅助（toRunes，UTF-8 切字函数）
  text.lua      — 手动换行（kinsoku + justify）/ 日期格式化
  draw.lua      — 颜色 / 渐变 / 二维码 / 装饰线绘制原语
  vertical.lua  — 竖排标题（分列 + 旋转 + 竖线）
  render.lua    — renderBB / render（渲染 + 写 PNG）
  init.lua      — 对外 API（本文件）

生产入口 `require("weread.lib.excerpt_card")`（薄 shim，见 book_excerpt_card.lua）。

@module koplugin.weread.lib.excerpt_card.init
--]]--

local Config = require("weread.lib.excerpt_card.config")
local Templates = require("weread.lib.excerpt_card.templates")
local Device = require("weread.lib.excerpt_card.device")
local Fonts = require("weread.lib.excerpt_card.fonts")
-- 只在同步绘制期间适配颜色，完成或失败后恢复 KOReader 的文本渲染。
local with_rgb32 = require("weread.lib.excerpt_card.rgb32")
local Assets = require("weread.lib.excerpt_card.assets")
local Text = require("weread.lib.excerpt_card.text")
local Draw = require("weread.lib.excerpt_card.draw")
local Vertical = require("weread.lib.excerpt_card.vertical")
local Render = require("weread.lib.excerpt_card.render")

local BookExcerptCard = {
    -- 子模块引用（便于测试/调试与调用方扩展）
    Config = Config,
    Templates = Templates,
    Device = Device,
    Fonts = Fonts,
    Assets = Assets,
    Text = Text,
    Draw = Draw,
    Vertical = Vertical,

    TEMPLATES = Templates.TEMPLATES,
    COLORS = Templates.COLORS,
    BACKGROUND_IMAGES = Templates.BACKGROUND_IMAGES,
}

local function valid_text(value, limit)
    return type(value)=='string' and #value<=limit and not value:find('[%z\1-\8\11\12\14-\31\127]')
        and require('weread.lib.protocol').utf8_substr(value,#value+1)==value
end
BookExcerptCard.renderBB = function(opts)
    if type(opts)~='table' or not valid_text(opts.text,4096) then return nil,'invalid_text' end
    for _,name in ipairs({'book_title','book_author','chapter','font_face','qr_url'}) do
        if opts[name]~=nil and not valid_text(opts[name],1024) then return nil,'invalid_text' end
    end
    return with_rgb32(Render.renderBB, opts)
end
BookExcerptCard.save = function(opts, directory)
    local image, dimensions = BookExcerptCard.renderBB(opts)
    if not image then return nil, dimensions end
    local ok, path, reason = pcall(require('weread.lib.excerpt_card.png').write, image, directory,
        type(opts)=='table' and opts.book_title or nil)
    image:free()
    if not ok then return nil, 'save_failed' end
    return path, path and dimensions or reason
end
BookExcerptCard.encode = function(opts)
    local image, dimensions = BookExcerptCard.renderBB(opts)
    if not image then return nil, dimensions end
    local ok, value, reason = pcall(require('weread.lib.excerpt_card.png').encode, image)
    image:free()
    if not ok then return nil, 'encode_failed' end
    return value, value and dimensions or reason
end
-- 暴露给调用方/测试的辅助
BookExcerptCard.footerBrandText = Device.footerBrandText
BookExcerptCard.backgroundImagePath = Assets.backgroundImagePath
BookExcerptCard.getStillnessHeadBB = Assets.getStillnessHeadBB
BookExcerptCard.clearStillnessHeadCache = Assets.clearStillnessHeadCache

return BookExcerptCard
