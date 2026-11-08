# 官方译文读取与原生双语显示

已完成真实只读前置验证、译文段落分析、原生阅读菜单、按书显示设置及实际阅读器切换。
已有译文可在本机离线显示；**缺失译文的获取／生成与实体 KO2 验收尚未完成，双语阅读整项仍在开发中。**

## 已验证的读取

`scripts/verify_translation_preflight.py` 默认离线，显式复用已保存的同账号 Web／墨水屏授权。
只允许会员概况、书架、指定书籍资料、完整目录、固定公开英文书搜索，以及已核对章节的正文读取。
目录 POST 是资料读取；`GET /trans/pdfepub` 会切换服务端模式，因此和生成、试用、购买、书架／进度写入一样被预检禁止。

- 书架回读 139 本；会员字段、两本在架书及两本公开搜索英文书的目录通过结构核对。
  负数价格在真实目录中存在，按未知处理，不能当成免费。只为明确免费或已购买且有正文的章节读取内容。
- 两本英文书的浏览器表示均解码为空，使用同一新鲜上下文的一次既有下载表示后，分别取得 49／34 个有文字的官方译文块。
  两种表示都有固定字段、同书／同章、大小和请求路径限制；HTTP 拒绝不触发循环重试。
  `hasTranslated`、版本、译文字数等元数据单独保存语义，不作为内容已经存在的证明；本次版本 0 的章节也确实提供了译文。
- 真实正文没有共享段落 ID。直接迁移的旧规则得到 0 对，已扩展为明确相邻、同层的无编号文字段落，最终识别 49／34 对。
  Python 对译文文字的计数与 Lua 模型一致，三种显示规则均可生成。
- 真实正文、目录、书 ID、位置、会话和内容摘要始终只在内存／私有管道中处理；报告只含状态、类型、数量和布尔值。
  没有译文模式变更、生成、试用、购买或账号数据写入。
  读取发现墨水屏授权 HTTP 401 后，按既有授权完成一次续期、同账号 139 本书架及钥匙串回读；刷新令牌省略时保留原值。
  另观察到 Web Cookie 更新，账号再次核对且钥匙串记录未被替换后保存／回读；两个授权条目继续保留到整体目标完成。

[真实去敏记录](validation-assets/2026-11-09/translation-owner-readonly.json)。默认离线复验：

```sh
python3 scripts/verify_translation_preflight.py
python3 scripts/test_translation_preflight.py
luajit spec/translation_spec.lua
```

显式只读与 Lua 模型核对（不触发生成）：

```sh
python3 scripts/verify_translation_preflight.py --saved-session --public-english --check-content --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation \
  ./luajit /source/spec/koreader/translation_preflight_probe.lua /source
```

## 显示与配对规则

`weread/lib/translation.lua` 适配 MiuRead `translation.lua` 的解析、字体和段落定位模型，来源已列入 NOTICE。
支持原文、双语、仅译文及有界字体比例。CSS 直接交给 KOReader 的 CRE 引擎，不使用网页界面。

有唯一共享 ID 的相邻原文／译文可配对；无 ID 时，只接受相邻同层、同为 p 的文字段落。
文字间隙、冲突 ID、恢复过的异常标记、容器、插图／公式或链接控制不能推定为可隐藏原文。
仅译文只隐藏已核对的原文；未配对内容保留，菜单展示已核对译文块和未配对块数量。
三种模式按实际原生 `DocFragment` 序号限定范围，重复段落 ID 不会影响另一章，旧 EPUB 不必添加额外 body 属性。
切换语言时定位到已配对段落的起点，不把一种语言的字偏移复制给另一种语言；双语模式保留原锚点。

## 实际阅读器流程

打开普通微信读书 EPUB 后，原生菜单提供「阅读语言」：原文、双语、仅译文与 80%—180% 译文字号。
选项保存在该本书的 KOReader sidecar 中；章节配对结果只在内存保存，不进入全局设置或内容缓存。
已有译文的检查和切换不发送 HTTP，也不切换服务端翻译模式或触发生成。
缺少译文时保留原文并给出提示，不能凭目录标志启用仅译文。

首次菜单检查由独立子进程重新打开 EPUB，按 container／OPF spine 的实际阅读顺序读取章节，
核对书籍／文件身份，拒绝重复、缺失、越界或歧义条目；不使用父进程的原生文档或 ZIP 句柄。
取消、旧回调、文件变动、账号／阅读会话变化和休眠后不再弹回菜单。
按书恢复非原文模式时，在首次排版前读取本地章节并核对原生已打开文件的 OPF／身份。
此恢复扫描是有界本地同步读取；大书开书耗时还需要后续性能专项测量。

显示 CSS 合并现有用户样式和划线样式。模式或字号改变走 KOReader 的一次原生重载，
关闭后只丢弃该文档的生成式排版缓存，EPUB 正文与书签坐标不被改写；
sidecar 新增显示选项，其余阅读状态由原生重载照常保存。
短暂内存交接绑定同账号、同文件、文件状态与已关闭的旧阅读会话，并核对新文档后恢复对应段落。
原文只读目标可保留来源坐标；切换不授予上传验证状态。
旧的未发送进度任务和新阅读器的延迟自动拉取会被取消，持久待上传意图仍保留。
保存失败、无效段落、阅读器忙或重载失败会停止切换并提供本地提示。

原生独立排版验证使用合成 EPUB、实际安装包及 CRE 引擎，在 600×800 和 KO2 1264×1680／300 DPI 下通过：
三种显示、共享 ID／无 ID、跨章相同 ID、未配对原文／链接保留、实际可见文字和段落目标均正确。
测试不改写输入正文；中文字体初始化和截图已检查。
[原生去敏记录](validation-assets/2026-11-09/translation-display-runtime.json)、
[600 原文](validation-assets/2026-11-09/translation-original-600.png)、
[KO2 双语](validation-assets/2026-11-09/translation-bilingual-ko2.png)、
[KO2 仅译文及保留内容](validation-assets/2026-11-09/translation-only-ko2.png)。

```sh
xvfb-run -a python3 scripts/test_translation_runtime.py \
  --koreader /path/to/koreader --run-dir /path/to/new-directory \
  --width 1264 --height 1680 --dpi 300
```

## 继续接入所需工作

- 无译文时的下载／按需生成与内容核对。模式切换／生成接口尚未真实验证，也未接入 Lua；不能凭目录标志宣称完成。
- 实体 KO2 的按键、休眠、文件系统与耗电验收。集中性能优化仍安排在全部功能开发及测试通过后。

## 原生阅读器验证

另用实际安装包、PluginLoader、ReaderUI、CRE、后台管道和原生菜单，在 600×800 和 KO2
1264×1680／300 DPI 的合成书籍中验证：三模式实际可见文字、跨章同 ID、段落交接、字号实际行高变化、
普通关书重开、原 EPUB 字节和本机书签位置保护、取消／休眠、旧上传及延迟拉取取消、持久意图保留。
两个运行均无 HTTP 和重绘失败，原生 DOM 不陈旧；这不替代实体 KO2 验收。
[完整阅读器去敏记录](validation-assets/2026-11-09/translation-reader-runtime.json)、
[KO2 阅读语言菜单](validation-assets/2026-11-09/translation-reader-menu-ko2.png)、
[600 双语正文](validation-assets/2026-11-09/translation-reader-bilingual-600.png)、
[KO2 仅译文](validation-assets/2026-11-09/translation-reader-only-ko2.png)。

```sh
luajit spec/translation_archive_spec.lua
luajit spec/translation_ui_spec.lua
xvfb-run -a python3 scripts/test_translation_runtime.py --reader \
  --koreader /path/to/koreader --run-dir /path/to/new-directory \
  --width 1264 --height 1680 --dpi 300
```
