# 下载已有云端译文与离线副本

原生阅读器「阅读语言」新增「下载本章已有译文」。取得并核对实际译文后，保存为独立的单章 EPUB，
可直接以双语模式打开；原 EPUB 及其本机书签／批注保留。原文档的阅读语言菜单也提供已保存副本的离线入口。
本项只获取已经存在的官方译文，不调用翻译模式修改、生成、试用、购买或进度写入接口。
没有现成译文时保留原书并提示；[缺失译文生成](translation-generation.md)仍未完成。

## 读取与独立保存

当前阅读视口先绑定账号、登录修订、文档、阅读会话、文件状态与归档来源元数据。
后台进程用独立 libarchive 描述符重新读取原 EPUB，核对文件身份、原文／渲染摘要及同章来源。
它不使用父阅读器的原生文档、DOM 或 ZIP 句柄。

只读适配器只允许同书阅读页、完整目录、当前章的四种 XHTML／样式分片。
章节请求必须保持同书／章、当前阅读上下文、完整字段、时间、随机数与签名，额外字段、其他章、TXT 通道及账号操作均拒绝。
响应在接收时限制大小；图片匿名读取，限制来源、跳转、单项／总量和数量。
取得正文后核对实际非空译文，保存前再次读取并比较完整目录和观察到的版本；不为旧文件重标版本。

父进程先独占创建 `.epub.part` 文件，子进程只向继承的描述符写归档并同步。
重新打开归档，核对译文、来源身份与原文元数据后，父进程核对完整大小，才独占预留新的 EPUB 名称并发布。
预留名称只替换本次拥有的空文件，已有副本不作为覆盖目标。
取消、翻页、关书、休眠、账号／凭据变化或迟到回调不能发布结果；未接受输出清理后仍保留原书。
本机清理与下载通过现有书籍操作锁互斥。

下载结果的本机入口写在原文档 sidecar 的独立字段，绑定账号、书／章、原文件身份和新文件身份。
不更新原书的主缓存路径，也不替换本机书签和批注。入口保存失败会提示，已经完成的副本保留。
离线打开前重新验证两个归档、当前原文位置和副本身份；不依赖上次下载时的段落目标。
副本必须是不同的物理文件；来源身份由内容推导，原文件已含相同译文且来源未变时，两者的来源身份可以相同。

## 对应原文位置

刷新可能增加译文节点或改变 EPUB 的片段序号，不能复制旧 XPath 或文字偏移。
原文节点按完整文字／子节点签名寻找唯一对应块，打开时定位到该块起点。
改变、重复、无法核对或有解析恢复的段落不推定相同；完成提示会明确说明将从本章开头打开。
新文档预先保存双语显示选项，正文由 KOReader 原生排版；此切换不授予云端上传验证资格。
本机批注留在原文件，跨副本批注迁移及整书译文更新尚待实现。

## 验证范围

- 新增 35 项读取白名单／段落映射检查、46 项原生控制器检查，旧语言界面 44 项检查继续通过。
- 267 组 Lua、139 个 Python 测试模块／1789 项、766 份 Lua 语法及 764 份静态检查通过，无跳过／警告。
- 600×800 与 KO2 1264×1680／300 DPI 实际 ReaderUI、HTTP 模拟服务、后台进程、原生归档及文件系统通过：
  下载十二个译文块、独立文件身份、双语正文、原文件／书签保护、离线入口、全新进程离线重开、取消及翻页清理。
- 两尺寸真实内核文件大小限制仅施加给子进程；实际 libarchive 写出失败后，父进程清理临时文件，原书及已保存副本保留。
- 原有三种语言显示、字号、重载／普通重开、位置与取消的两尺寸完整原生回归通过。
- 真实账号的新适配器只读对照通过：Python 与 KOReader Lua 独立 HTTPS 读取两本英文书，49／34 个译文块及完整原文字节一致。
  私有正文、身份、摘要与凭据只经内存管道；没有真实截图或账号数据修改。六秒采集与生成测试范围前后保持。
  初轮实际 HTTP 401 经独立复核后，只续期一次并核对同账号／钥匙串回读，旧采集与消费记录保持；初始化失败记录也保留。
- 真实账号的完整阅读器组合随后在两尺寸通过：把独立读取的真实同章正文按正常内容模块生成原 EPUB，
  从实际 ReaderUI 阅读语言菜单下载、打开双语副本，并由全新原生进程从原书的已保存入口离线重开。
  真实译文有原生可见字符，原文字节、原书、书签与主缓存路径保持。每尺寸在线原生阶段十次限域读取，离线阶段零请求。
  入口从真实本机原书开始；本用例没有重新验收首页／书城选书，也不代表实体 Kindle 验收。
- 该真实样本在两端均未返回阅读位置，书籍信息各返回一个时长字段。
  只读验证单独识别这类明确响应，保留位置缺失和实际字段的存在／值，前后同时比较完整书籍信息及书架。
  不把未返回位置或计数补零，不宣称完整三项阅读计数已核对，也不改变写入预检要求。
  初轮无法识别基线的结果保留为未验证；后续明确识别后才执行原生界面流程。
- 真实凭据只经内存管道和匿名文件描述符；正文、sidecar、SQLite 与归档在 Linux tmpfs 临时资料中，
  两个原生进程后删除。零真实截图、零账号数据／授权／模式／生成请求；原采集、消费记录与登录继续保留。
  新增 21 项验证器检查覆盖缺失值、字段类型、跨账号回执、离线请求、重复／超限消息和不完整结果。

[固定结果记录](validation-assets/2026-11-17/translation-fetch.json)、
[真实原生组合记录](validation-assets/2026-11-17/translation-fetch-owner.json)、
[600 完成提示](validation-assets/2026-11-17/translation-fetch-result-600.png)、
[KO2 双语副本](validation-assets/2026-11-17/translation-fetch-bilingual-ko2.png)。截图均为合成书籍。
298 份候选包文件与源码及两个实际安装目录逐字节一致。

缺失译文生成、整书更新与批注迁移、更多资源格式、
真实存储写满／断电和实体 Kindle Oasis 2 尚待验收；不能以当前两尺寸模拟器或接口对照代替。

默认离线及真实只读对照：

```sh
python3 scripts/verify_translation_fetch.py
python3 scripts/test_translation_fetch.py
python3 scripts/verify_translation_fetch.py --saved-session --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/translation_fetch_http_probe.lua /source
```

完整原生合成流程与独立离线进程：

```sh
xvfb-run -a python3 scripts/test_translation_runtime.py --fetch \
  --koreader /path/to/koreader --run-dir /path/to/new-directory \
  --width 1264 --height 1680 --dpi 300
```

真实账号原生组合（默认运行不访问账号；临时资料要求 Linux tmpfs；候选包须与当前生产源码一致）：

```sh
python3 scripts/verify_translation_fetch_owner.py
python3 -m unittest discover -s scripts -p test_translation_fetch_owner.py
python3 scripts/verify_translation_fetch_owner.py --saved-session --native-ui-command \
  docker exec -i weread-validation xvfb-run -a \
  python3 /source/scripts/run_translation_fetch_owner.py \
  --koreader /validation/runtime/lib/koreader \
  --candidate /validation/translation-fetch-candidate-v1.zip \
  --width 1264 --height 1680 --dpi 300
```
