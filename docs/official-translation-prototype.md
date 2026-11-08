# 官方译文读取与原生显示核心

本轮完成真实只读前置验证、译文段落分析和 KOReader 原生排版核心。
**阅读菜单、按书设置保存、实际切换协调尚未接入；双语阅读整项仍在开发中。**
没有把模型或独立排版测试当成完整阅读器功能验收。

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
仅译文只隐藏已核对的原文；未配对内容保留，模型提供部分覆盖状态供后续界面解释。
三种模式按实际原生 `DocFragment` 序号限定范围，重复段落 ID 不会影响另一章，旧 EPUB 不必添加额外 body 属性。
切换语言时只产生对应段落起点的定位建议，不把一种语言的字偏移复制给另一种语言；双语模式不改变原锚点。

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

- 依照实际 OPF spine 顺序读取当前 EPUB，核对书籍／文件身份后建立章节序号，不能从目录或 ZIP 条目顺序猜测。
- 原生菜单和按书模式／字体设置，合并用户样式及现有划线样式；已有译文离线显示不依赖会员概况读取。
- 初次开书恢复、切换后的重新排版、段落锚点及原文位置状态保护，避免样式反复重载；失败回退不隐藏未核对内容。
- 取消、旧回调、账号变化、休眠、关书和文件变动时停止自有工作；真实阅读器流程及设置重开验收。
- 无译文时的下载／按需生成与内容核对。模式切换／生成接口尚未真实验证，也未接入 Lua；不能凭目录标志宣称完成。
- 实体 KO2 的按键、休眠、文件系统与耗电验收。集中性能优化仍安排在全部功能开发及测试通过后。
