# 书籍脚注转换与原生显示

已修复下载转换产生的重复脚注：同章原始注释块在内容核对后替换，
同一目标的多个引用共用一份脚注，并保留每个引用的返回链接。
同名但来自不同章节的目标不会互相删除；文字相同的独立脚注不会仅凭文字合并。
原始目标和引用的锚点保留，普通注释链接仍能跳转。

扫描识别完整标签边界、嵌套、引号内的 `>`，忽略注释、CDATA、script 和 style 中的伪标签。
仅对能完整匹配的本地文字注释删除原块。含图片、公式、表格或引用链接的目标保留原 HTML 与链接；
歧义目标不任意选择，无法安全处理的重叠定义保留整章原始内容。
现有缓存不会自动改写，新下载或明确重新下载的章节使用新转换结果。

脚注仍使用标准 EPUB 语义，显示由 KOReader 的原生设置控制：
可使用弹窗、跳转到章末、显示页下注，以及将章末注释标记为非线性后隐藏。
页下注与章末注释是否同时显示取决于这些设置；修复不强制隐藏或关闭其中一种。
对应原生规则见 [KOReader 样式设置](https://github.com/koreader/koreader/blob/v2026.07.1/frontend/ui/data/css_tweaks.lua)。

复杂注释在开启弹窗时另有保真处理：原生弹窗没有书内资源解析和可点击链接处理，
已实际复现图片只显示 `[image]` 占位。插件识别原生检测选中的注释片段，
遇到图片、SVG、MathML、表格或资料链接时，由 KOReader 直接跳转到书中原注释，
使用完整阅读器显示内容；可继续点击引用资料，并通过原生返回操作回到阅读位置。
纯文字以及生成的返回链接仍使用原生弹窗。此处理仅安装在当前微信读书文档实例，
关书时恢复；不改写 EPUB、原文坐标或全局脚注设置，也不增加网络请求。
它不把复杂注释转换成纯文字，不宣称已为弹窗实现完整媒体支持。
接口行为核对自官方版本的 [ReaderLink](https://github.com/koreader/koreader/blob/v2026.07.1/frontend/apps/reader/modules/readerlink.lua)
和 [FootnoteWidget](https://github.com/koreader/koreader/blob/v2026.07.1/frontend/ui/widget/footnotewidget.lua)。

## 验证

- 修改前复现原始 aside 与新生成脚注同时保留，同一注释文字在 XHTML 中出现两份。
- 脚注规格从 58 项增至 106 项：覆盖共享引用、各返回链接、旧锚点、九种块布局、
  嵌套别名、同名跨章、相同文字不同定义、邻接锚点、注释／CDATA、引号、媒体／引用保留与损坏结构。
- 新增 7 个独立 Python 检查，验证实际 Lua 输出的 ZIP／XML、五个引用共用四个目标、
  每个引用的返回链接、重复 ID、失效旧链接及原始复杂注释保留；不再假设引用数等于脚注份数。
- 官方 KOReader v2026.07.1 Linux ARM64／Xvfb 的 600×800 和 1264×1680／300 DPI，
  通过实际点击验证两处共享引用的弹窗各只含一份内容、原始锚点跳转、返回、页下注开关、
  隐藏非线性章末注释后继续访问与恢复显示。实际 CRE 全文查找的共享脚注匹配数为一。
- 正常插件选书、目录／章节下载、ReaderUI 中的脚注点击和弹窗也在两尺寸通过，
  再完成翻页、模拟同步回读、离线保存、重连选择和核心回归。

- 复杂脚注新增 44 项独立检查：媒体／引用识别、CRE 重写后的返回锚点、转义及注释伪标签、
  原生扩展片段、返回值、异常恢复、文档切换及后装钩子保留。
- 两尺寸实际插件实例中，四类复杂注释均进入原内容，SVG 图、分数／根式和完整表格经目视检查，
  引用资料可点击，四次返回与原 XPointer 完全一致，纯文字仍弹窗显示，关书后钩子恢复。
  Python 独立解析 ZIP／XML，确认五处引用、五个注释、仅一份生成文字注释，图像资源确实在包内。
- 原有共享引用／旧锚点／页下注／隐藏注释的两尺寸完整流程重新通过，且这次显式要求实际实例保护已安装。

显示验证均为合成资料，未访问真实账号。更多真实书籍格式、
旧缓存重新下载后的真实记录、实体 KO2 等仍待验收；不据此宣称全部脚注格式已支持。
原始格式中的复杂内容保留不等于其所有原生显示方式均已验收。

复验：

```sh
python3 scripts/test_book_footnotes.py
xvfb-run -a python3 scripts/test_discovery_runtime.py --footnotes \
  --koreader /path/to/runtime --run-dir /path/to/new-test-directory
xvfb-run -a python3 scripts/test_discovery_runtime.py --rich-footnotes \
  --koreader /path/to/runtime --run-dir /path/to/another-new-directory
```

KO2 尺寸追加 `--width 1264 --height 1680 --dpi 300`；每次使用新目录。
结果见[去敏报告](validation-assets/2026-11-09/book-footnotes-runtime.json)和[本轮验证](validation-2026-11-09.md)。
复杂注释保真跳转与本轮回归另见[验证报告](validation-assets/2026-11-12/rich-footnotes.json)。
