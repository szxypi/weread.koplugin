# 公众号缓存文章导出

在公众号文章列表选择「导出缓存文章」，再选择一篇已经缓存的文章并确认导出。
阅读已识别的公众号文章时，也可从「工具 → 微信读书 → 导出文章为 EPUB」进入。
成功后可直接打开导出的 EPUB，或到插件数据目录的 `exports/articles/` 复制文件。
导出不要求联网或重新登录，不新增公众号目录、订阅或账号数据写入。
从「已保存版本」阅读旧文章时，当前文章导出保持正在阅读的旧版来源，不切换到最新缓存。
单篇刷新及旧阅读记录保留见[版本说明](mp-cache-versions.md)。

## 内容

- HTML 缓存转为单篇 EPUB，保留中文文字、段落、标题、常用强调、列表、表格、内部锚点及明确的 HTTPS 链接。
  包内有独立目录和书名／公众号名称。公众号、书架 ID、Reader 会话和进度字段不进入新包。
- 正文只使用当前已保存的内容；不执行 JavaScript 或读取远程样式。
  旧样式及主动／嵌入组件不进入转换后的文章，阅读字号和排版交给 KOReader。
- 将这篇文章自己图片目录内的 PNG／JPEG／GIF／WebP 文件流式打包；重复引用共享一个包内文件。
  旧 HTML 中的内嵌位图也可打包。图片类型按内容签名识别，不仅看扩展名。
  其他文章目录、路径穿越、绝对路径、远程 URL 和符号链接均不作为图片文件读取。
- 缺失、无法识别类型或不可读取的图片保留文字占位，成功窗口列出未包含的图片引用数量。
  「包含图片」为包内实际图片文件数，重复引用不重复计数。不自动联网补图，也不修复原缓存图片的数据损坏。
- 旧缓存已经是 EPUB 时，核对容器后逐字节复制，保留旧包的内容与表现；不把旧包重写成新转换格式。
  旧包原有的资源完整性、外部链接与格式限制也保留，不宣称旧包中的远程资源已离线化。
- 新下载的文章已按身份分目录，同名文章可以分别导出，详见[缓存说明](mp-article-cache.md)。
  对仍按标题命名的旧缓存，当前保存目录存在不同身份指向同一文件时，导出选择器提示重新下载并禁止选择。
  当前阅读入口也拒绝这种歧义，避免把另一篇缓存误称为所选文章。

## 后台与文件保护

确认前固定账号、界面代次、阅读会话、文档和路径，正文只由独立子进程读取。
子进程自行打开缓存文件，不使用父进程的原生文档、DOM 或 ZIP 对象。
输入与图片均核对文件身份、大小和修改时间；身份、大小或修改时间变化时拒绝结果；这些检查不构成文件系统的原子快照。

每次排他创建一个新文件，POSIX 初始权限 `0600`；名字冲突递增序号，不截断已有导出。
libarchive 直接写入这个文件描述符，不通过路径重新打开输出。
同步成功、身份和字节数一致后才提示完成；打开按钮还会再次核对文件。
取消、关闭界面、切换账号、关书／休眠、会话变更、超时或失败会停止自有任务并删除仍属于本次的文件。
旧弹窗／回调不能启动导出、打开替换文件或关闭新任务。成功导出不随关窗删除。
与本机笔记导出一样，不保证进程崩溃或断电后的半成品自动清理。

导出选择器与当前文章识别最多检查 1,000 条已保存记录。
HTML 输入最多 4 MiB，单个本机图片最多 32 MiB，总图片最多 64 MiB／512 个，输出最多 72 MiB。
超限停止，不截断正文或图片后声称导出成功。
导出文件即便位于自定义缓存根目录内，也排除在微信读书书籍识别之外，避免触发云端位置同步。

## 证据与复验

真实只读转换使用仓库已验证过的文章样本：Python GET 与插件独立 HTTPS GET 后，
转换文本及 3 个图片占位和 Python 独立 HTML 解析投影一致。
未读取公众号目录、下载远程图片或续期，没有真实导出文件、正文、凭据或内容摘要落盘。
[真实去敏报告](validation-assets/2026-11-09/mp-export-owner-readonly.json)只含状态、数量和布尔值。
这不代表所有文章类型、真实图片缓存、公众号目录或实体 KO2 已验收。

```sh
python3 scripts/verify_mp_export.py
python3 scripts/test_mp_export.py
luajit spec/mp_export_spec.lua
luajit spec/mp_export_ui_spec.lua
python3 scripts/verify_mp_export.py --saved-session --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/mp_export_probe.lua /source
```

模型 40 项与操作协调 46 项检查覆盖文字／格式、未知与主动标记、图片引用、UTF-8、容量、
文件身份、缓存歧义、弹窗生命周期、取消／旧回调、账号／文档／会话／路径及存储失败。
另有 5 组默认离线 Python 检查验证读取边界、独立文本投影和子进程私有输出。

原生场景 `spec/koreader/mp_export_smoke.lua` 随完整核心运行，在 600×800 与 KO2
1264×1680／300 DPI 下核对实际文章列表、阅读菜单、确认／完成窗、后台心跳、EPUB／CRE、
图片字节、重复／内嵌图片、占位、缓存根目录、旧 EPUB 保持、取消／身份／存储／大小／符号链接边界。
当前文章菜单由合成文件身份触发，完成窗的打开按钮核对交给共享文件打开流程的路径；
导出包由独立 CRE 文档实际加载、解码图片并定位到可见图片，并非一次新 ReaderUI 实例的完整打开验收。
截图、文章和图片全是合成数据；自动阅读上报仅在测试中关闭，生产配置不变。

```sh
WEREAD_TEST_OFFLINE_TIME=1 xvfb-run -a python3 scripts/mock_weread.py \
  --smoke --port 0 --koreader /path/to/koreader --run-dir /path/to/new-directory \
  --width 1264 --height 1680 --dpi 300
python3 scripts/check_mp_export_package.py /path/to/new-directory
```

[原生与包检查记录](validation-assets/2026-11-09/mp-export-runtime.json)、
[600 确认](validation-assets/2026-11-09/mp-export-confirm-600.png)与
[KO2 完成](validation-assets/2026-11-09/mp-export-success-ko2.png)使用合成数据。

独立包检查核对 ZIP CRC、首个未压缩且无附加字段的 `mimetype`、XML、container／manifest／spine、
目录、中文元数据／文字、图片路径与签名，PNG 分块 CRC／像素解压，以及旧包复制字节。它不等同于完整 EPUBCheck 或所有阅读器兼容验收。
结构依据 [W3C EPUB 3.3](https://www.w3.org/TR/epub-33/#sec-ocf-zip-container)，
描述符写入依据 [libarchive 官方接口](https://github.com/libarchive/libarchive/blob/master/libarchive/archive_write_open.3)。
实体 KO2、更多真实内容与整项功能后的集中性能优化继续待办。

新的后台下载使用文章身份／代次图片目录，导出器已支持在同一身份下读取这些位图，
仍兼容原固定图片目录；跨文章代次、路径穿越和目录符号链接不被读取。
下载时已经转换为文字的缺图占位会原样导出，不计入导出阶段的缺图引用数。
