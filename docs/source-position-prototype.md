# 原文位置：公开页面与当前网页解析器验证

当前阅读流程仍使用目录字数和文档百分比。原文坐标的 Lua 转换核心已实现，尚未绑定实际 EPUB 或接入阅读／上传流程。
`scripts/verify_source_coordinates.py` 为下一步迁移准备 Python 原型，参考 MiuRead 的
`wr_co.lua`、`source_position.lua`，并在 2026-11-08 调用微信读书当前官方网页解析器核对。

## 实际证据与边界

初次 [去敏报告](validation-assets/2026-11-08/web-source-coordinates-public.json) 保留为 `PARTIAL`：

- 无登录读取一本书的公开预览，页面和三个正文分片均 HTTP 200。解码正文为 887 字节／774 个 UTF-16 单位，
  当前网页解析器生成的 67 个正文节点位置与原始坐标模型匹配。
- 另用合成正文验证常规标签、图片标签、引号、实体、换行、BOM 和补充平面字符。
  支持标签的组合样例核对 417 个节点；第一版原始坐标模型遇到改写标签时拒绝输出位置。
- 网页使用 UTF-16 位置，不能直接使用目录字数或 Lua UTF-8 字节数。表情会占两个单位；
  当前网页解析器将样例表情拆成两个替代字符节点。原型记录这两个节点，反向定位拒绝落在标量内部。
- 部分数字实体在当前网页中按字面显示，普通命名实体可以解码；CR 在 DOM 中变为 LF，
  但后续位置仍按原始长度推进。不能先解码实体／改换行，再将新下标冒充服务端位置。
- **原始 XHTML 坐标并不适用于所有标签。** 对 74 种标签分别调用当前解析器后，
  `a`、`figure`、`figcaption`、`q`、`rp`、`rt`、`ruby`、`samp`、`source`、`strike`、`summary`、`wbr`
  的正文位置出现差异。测试中忽略标签内的文字从该标签起点计数，后续正常段落又恢复其原始位置；
  简单删去这些标签后整体重新计数同样不匹配。脚本／样式或未知正文标签也不能直接套用原始下标。
  工具同时复验这 15 类反例，报告逐项记录原始模型和删标签模型均不匹配。
- 因此没有直接移植 MiuRead 的完整原始 XHTML 下标假设，也没有改变 Lua 上传位置。
  未验证真实账号的位置写入、回读或多设备行为。公开预览不能证明整本书、TXT 和所有 HTML 结构都适用。

浏览器使用新建的非持久会话，不读取日常浏览器设置。只允许微信读书站点和其 CDN 的 HTTPS GET；
后台 HTTP 写请求及其他来源均阻断，服务工作线程关闭，结束后关闭浏览器。
分片请求使用不带 Cookie 的独立客户端，只允许读者页和三个既有正文读取端点，不接受跳转。
正文、会话参数和原始节点仅在内存比较；报告只有状态、数量、摘要、公共资源 URL 和布尔值。
没有扫码、导入 Cookie、修改书架或上传进度／时长。

## 过滤后的计数规则与 Lua 核心

后续 [Python／Lua 对照报告](validation-assets/2026-11-08/web-source-coordinates-filtered-lua.json)
仍为 `PARTIAL`，但上述 15 类反例的转换规则已通过当前网页解析器核对：

- 白名单标签保留自己的原始位置；标签后文本从原始标签末尾开始计数。
- 两个保留标签之间，被忽略标签的文字拼接到同一段，忽略标签和注释的长度不计入这段。
  原有实体保持编码长度，文本中的裸角括号先转义。遇到下一个保留标签重新取其原始位置。
- 29 组公开／合成正文共 978 个网页节点与新模型匹配，包含原先无法用原始或整体删标签模型解释的 15 类反例。
- Python 随后将正文及查询通过内存输入交给官方 KOReader 的 Lua／JSON 环境。
  Lua 自行分词得到的文本段、规范化正文和 39 个局部定位结果与 Python 一致，且对应同一批实际网页节点。
  没有保存正文或凭据；这不是 ReaderUI 的跳转验收。

`weread/lib/source_coordinates.lua` 实现这套本地转换，支持 UTF-16、BOM、实体、前后文消歧和反向上下文。
每 256 个文本单元建立稀疏检查点，避免为整章每个字符保存一个 Lua 表；输入正文限制为 2 MiB，查询限制为 8 KiB。
79 项 Lua 检查覆盖实际观察的坐标、长章节跨检查点、重复／重叠句子、章节末尾上下文、
多字符实体、错误格式和反向歧义。角括号转义后，文本段可能覆盖下个标签的坐标区间；
一个云端坐标可能对应多个位置，此时拒绝反向定位，不选择第一处。

[合成压力结果](validation-assets/2026-11-08/source-coordinate-lua-benchmark.json) 验证了 1 MiB、2 MiB 正文及
2 MiB 裸角括号大量转义的情况，均完成构建和正反向查询。2 MiB 两例为 8192 个检查点；
不含源字符串的 GC 后 Lua 保留内存增量约 4.8／10.3 MiB，构建和查询 CPU 时间约 0.61／1.75 秒。
这是 Linux ARM64 容器结果，不是峰值 RSS 或 KO2 性能；后续接入须在后台准备，翻页不能同步重建整个索引。

当前只加载验证核心，未更改 `ProgressSync`、`PositionMapper` 或上传请求。
仍须完成原文与打开文件的绑定、CREngine XPointer 对照及真实账号写后回读；短文本、纯图片、TXT、
扩展实体和包含复杂原始脚本／CDATA／多个 body 的来源也不能由本次结果宣称完成。

## 复验

默认只做离线边界检查，不联网，不需要浏览器依赖：

```sh
python3 scripts/verify_source_coordinates.py
python3 scripts/test_source_coordinates.py
```

22 组离线检查覆盖 UTF-16／BOM、标量内部拒绝、实体原始跨度、正文边界、标签拒绝、重复及重叠文本、
前后文消歧、不可匹配拒绝、网页表情替代字符、数字实体字面显示、请求范围及默认命令不联网。
另覆盖过滤后文本段、重设位置、嵌套／自闭合标签、角括号展开、注释移除、坐标歧义及 Lua 比较结果核验。
已纳入 CI；测试不启用真实浏览器或访问账号。

公开页面与实际官方解析器复验需要单独的 Python 环境、Playwright 和系统 Chrome：

```sh
python3 -m venv /path/to/source-position-tools
/path/to/source-position-tools/bin/python -m pip install playwright
/path/to/source-position-tools/bin/python scripts/verify_source_coordinates.py \
  --public --book-id 3300237584 --output /path/to/new-coordinate-report.json
```

本次使用外层 `.validation/source-position-tools/`、Playwright 1.64.1、Chrome 157.0.8103.39。
官方脚本的公共资源路径保存在报告中；查找已加载解析器的导出契约，未硬编码模块编号。
官方模块导出、已支持样例或反例行为变化会停止，不以旧实现的测试结果代替新解析器核对。

使用当前工作区的只读容器和真实 KOReader 核对 Lua（命令参数必须放在最后）：

```sh
/path/to/source-position-tools/bin/python scripts/verify_source_coordinates.py \
  --public --book-id 3300237584 --output /path/to/new-lua-coordinate-report.json \
  --lua-command docker exec -i -w /validation/runtime/lib/koreader \
  weread-validation ./luajit /source/spec/koreader/source_coordinate_probe.lua /source
```

正文及查询只走标准输入／输出内存管道，报告不包含它们；核验失败只报告受控原因，不回显子进程输出。


## 继续接入所需工作

1. 常用标签过滤模型及 Lua 核心已完成；继续核对复杂格式、短章／图片／脚注和 TXT，保留反例与反向歧义检查。
2. 下载时保留原始坐标来源，并与实际打开 EPUB 的章节、Web 版本和正文摘要绑定。
   改写图片地址、移除脚注定义后的正文或全局最新缓存不能充当同一份原文证明。
3. 用真实 CREngine 的当前位置和上下文定位原文；反向通过正文定位 XPointer，验证章节边界、重复段落、
   字体／排版变化、旧文件、同路径替换及账号／会话取消，不能以页面百分比代替精确位置。
4. 完成真实只读位置对照后，再验证明确授权的一次进度写入与独立回读；多设备和实体 KO2 另行验收。

以上仍是原始目标中未完成的精确进度工作，不将本原型的局部验证记作插件功能已完成。
