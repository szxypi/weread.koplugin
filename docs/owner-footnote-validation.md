# 真实图标脚注的内存验证

本批使用已保存的开发登录，按目录中可读章节取样。每个尺寸独立读取 8 本普通数字编号书籍、
32 个章节；14 条脚注以图片图标的属性保存注释文字，而不是源 XHTML 中的 `<a href>`。
Python 提取的候选数量与生产 Lua 转换器一致，生成的脚注目标全部通过校验。

在官方 KOReader v2026.07.1 Linux ARM64／Xvfb 中，600×800 与 1264×1680／300 DPI
各完成 14 次原生弹窗、14 次关闭弹窗后的原文跳转和 14 次返回。
每次核对原生手势选中的目标、弹窗 HTML 的完整可见文字、正文位置不因弹窗改变，
以及跳转后的原生返回目标与页码。实际插件初始化和复杂注释保护均已启用。
本项是程序化运行时验证，没有人工目视正文截图。

## 数据与账号范围

- 复用既有受限的账号、书架、进度、目录和正文读取协议。书籍范围、章节 UID、阅读会话和
  前后进度均核对；单次最多取 8 本、每本 4 章，不包含续期、书架、笔记、时长或进度写入。
- Cookie 只在本机读取；读取过程中发生变化时，重新核对账号，再保存到钥匙串。没有主动续期。
- 书名、编号、正文、注释和弹窗 HTML 只通过内存与管道传递。Lua 渲染进程没有账号凭据。
- 原生渲染所需 EPUB、阅读器配置和缓存仅写入 Linux `/dev/shm` 的临时目录。
  退出前结束并回收子进程，删除临时目录；返回成功前再次检查目录已不存在。
- 渲染使用合成书籍身份。此处验证真实内容的转换和原生交互，真实账号同步组合另行验收。
- 普通插图没有在本批打包或联网获取；本批不保存正文截图。报告仅有固定标签、数量和布尔值。

候选插件与源码、实际安装逐文件核对，共 264 个文件。
这些是本批开始时已通过 CI 的 `45e36b4` 生产文件，本批只新增验证工具和证据。

## 保留的失败及复核

首次原生文字核对在第 8 条脚注失败：转换后的内容包含完整预期文字，原生弹窗提取结果
比预期多出排版格式字符。改用独立 HTML 解析后继续复现，再定位到原生新增的一个
U+00AD 软连字符；来源中没有这个字符。

验证器按可见文字核对，处理 HTML 实体、空白和软连字符。可见连字符、标点与正文字符
仍须保留，缺字和不同文字仍失败。该场景修复的是验证器，生产转换代码没有为通过测试而更改。
失败记录和随后两尺寸的复核计数保留在[去敏报告](validation-assets/2026-11-12/owner-footnotes.json)。

新增 25 项离线检查覆盖默认不访问凭据、只读网络范围、请求预算、源数据投影、目录歧义、
私密管道边界、返回字段过滤、原生弹窗文字差异、软连字符与可见连字符的区别，以及临时目录清理。
既有 233 组 Lua 检查继续通过。

## 复验

先准备与源码一致的候选包。验证默认离线，不读取登录：

```sh
python3 scripts/verify_owner_footnotes.py
python3 scripts/test_owner_footnotes.py
```

实际读取须显式使用 `--saved-session`，原生渲染示例：

```sh
python3 scripts/verify_owner_footnotes.py --saved-session --max-books 8 \
  --chapters-per-book 4 --native --lua-command \
  docker exec -i -w /source weread-validation \
  flock -x /validation/weread-native-ui.lock xvfb-run -a \
  python3 scripts/run_owner_footnote_probe.py \
  --koreader /validation/runtime/lib/koreader --candidate /path/to/candidate.zip
```

KO2 尺寸为渲染器追加 `--width 1264 --height 1680 --dpi 300`。
`--native` 要求全部预期脚注完成弹窗文字、跳转和返回；失败时只输出固定诊断计数。

## 待完成

本批源章节没有普通锚点引用或外章原链接，不能据此确认真实跨章节链接。
真实图片／公式／表格等复杂注释、更多编号与格式、实体 KO2、硬件休眠／断电和云同步组合仍待验收。
相关已完成的合成导航见[单章导航说明](standalone-chapter-links.md)。

## 分批扩展来源样本

工具新增 `--book-offset 0..4999` 与 `--chapter-offset 0..9999`，默认为零，保持既有抽样方式。
书籍偏移在格式筛选、去重和注释类书名优先排序之后应用；章节偏移在当前章、注释章、其他可读章的去重排序之后应用。
每批仍最多八本、每本最多四章，网络请求／内存字节限制不变，不会因到达末尾自动从头重读。
偏移针对本次书架排序；其他设备改动书架顺序后，不保证与历史批次完全无重叠。
新增八项边界检查覆盖窗口去重／截断、章节优先级、非法值在请求前拒绝和离线报告；该文件现有 33 项检查全部通过。

例如跳过当前排序前八本，读取下一批：

```sh
python3 scripts/verify_owner_footnotes.py --saved-session --max-books 8 \
  --book-offset 8 --chapters-per-book 4 --native --lua-command \
  docker exec -i -w /source weread-validation \
  flock -x /validation/weread-native-ui.lock xvfb-run -a \
  python3 scripts/run_owner_footnote_probe.py \
  --koreader /validation/runtime/lib/koreader --candidate /path/to/candidate.zip
```

若选择范围没有可读内容，会明确返回空样本或失败，不把未读取的章节算作通过。

2026-11-12 的[扩展实测](validation-assets/2026-11-12/owner-footnotes-expanded.json)在两个尺寸各检查当前排序第 9–16 本候选，共八本／32 章。
每个尺寸实际打开六章原生阅读器，完成 40 条图标脚注的完整可见文字、弹窗、跳转和返回；其余章节仅完成转换及模型核对。
另识别六个外部链接，未点击；样本没有原始跨文件链接，也不能证明复杂媒体脚注已验收。
KO2 首轮在一次读取未取得 HTTP 状态时中断，原记录保留，具体异常未分型；新增固定传输原因／已知阶段诊断后，
全新只读复验通过。成功的两轮各 163 次读取，均为 HTTP 200；所有尝试均零账号数据修改、零授权续期、无真实正文截图。
候选包与当前 269 个生产文件逐字节一致，本轮没有修改生产逻辑。
