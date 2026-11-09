# 真实账号的原生界面只读验证

本页分开记录早期内存文字探针与后续文件缓存组合验收。后者使用实际文件数据库、封面及可见进度，
并在全新进程中离线重开；原有文字探针的边界仍保留，不合并扩大其证明范围。

`scripts/verify_native_ui.py` 默认离线；显式复用已授权保存的项目会话后，
先由 Python 读取一次书架和一本同架书籍的资料，再让打包插件独立读取并显示真实数据。
本项补充已通过的接口投影、合成 HTTP、原生控件和缓存验证，不修改产品功能或默认设置。

## 内存文字探针范围

官方 KOReader v2026.07.1 Linux ARM64／Xvfb，KO2 的 1264×1680／300 DPI、灰度缓冲区。
真实书架 139 本，界面分组 6 项（含未分组）；实际显示列表第一页和第二页、首页、
同书资料、搜索、相似书籍和个性化推荐，共 7 次原生重绘。
搜索和相似首批各 20 本，真实个性化推荐为空；空列表同样完成原生绘制。
详情保存及控件字段与 Python 独立读取投影一致，工作进程读取期间主界面定时回调可执行。

本项关闭封面下载和可见进度查询，不证明这两条真实账号链路已完成界面验收。
独立的[封面链路验证](shelf-cover-prototype.md)另用一张真实 JPEG 与合成名称，完成两尺寸匿名读取、缩略与绘制；
它不扩大本文文字探针的范围，也不代表完整真实书架封面或可见进度界面已验收。
不读取正文或真实笔记，不发送书架／进度／时长／划线等数据写入，不在界面探针中续期。
网络请求限于五个明确的 GET，每个最多一次：书架、同书资料、固定公开词搜索、同书相似和推荐。
核对原生账号和授权头，拒绝 Cookie／Authorization、其他路径、POST、重复请求或响应 Cookie 保存。
没有截图、人工观察真实页面或实体按键／触摸验收；本项证明自动调用、数据绑定及原生绘制未抛出错误。
非空个性化推荐、后续批真实界面、Web／Skill 回退、账号切换与设备表现继续分别验收。

## 内存环境及适用边界

- 原生授权和账号范围使用 Linux 匿名内存描述符，仍由实际账号范围与授权记录读取代码核对；
  不创建可持久保存的凭据文件，不把凭据放入命令参数。
- 普通设置字段仍走实际设置类的读写逻辑，底层偏好使用内存对象；
  本机书籍记录使用内存表，`flush` 不写磁盘。
  实际 LibraryDB SQL、表结构、查询与事务运行在同一条 `:memory:` SQLite 连接，关闭由验证进程统一执行。
  因此本项不证明真实资料的磁盘持久化、数据库重开或进程重启恢复；这些能力保留合成环境的独立证据。
- 页面调用、资料投影、后台读取、内存管道、列表／详情控件和重绘使用实际插件实现。
  不替换网络响应。封面请求与可见进度调度被明确停用，其余调用受固定 URL／方法／账号／次数约束。
- 源码需位于新配置的 `plugins/weread.koplugin`；已有插件数据或设置时拒绝开始。
  结束前审计隔离配置内的生成文件，排除安装包源码，核对没有写入被检查的授权、账号、书籍标识或标题。
  子进程输出只通过捕获的管道解析，公开结果只允许固定字段、数量、阶段和布尔值，失败不输出原始异常或私有诊断。

不能把内存后端的成功称为完整真实账号环境或完整设备验收。
没有重写已有配置、缓存或钥匙串条目；开发授权继续保留到整体目标完成。

## 执行

先在工作区外准备新的候选包和隔离配置，将候选包解压到该配置的 `plugins/`。
不要复用运行过的目录或日常阅读器配置。

```sh
python3 scripts/verify_native_ui.py
python3 scripts/test_native_ui.py

python3 scripts/verify_native_ui.py --saved-session --lua-command \
  docker exec -i -e KO_HOME=/validation/new-owner-ui/profile \
  -e EMULATE_READER=1 -e EMULATE_READER_W=1264 -e EMULATE_READER_H=1680 \
  -e EMULATE_READER_DPI=300 -e EMULATE_BW_SCREEN=1 -e EMULATE_BB_TYPE=BB8 \
  -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/native_ui_probe.lua \
  /validation/new-owner-ui/profile/plugins/weread.koplugin
```

只有已确认的有效原生授权可以继续；HTTP 401 时停止，界面探针不自动重发或续期。
本轮预检曾返回 401，之后由独立的既有续期工具维护一次授权，
同账号 139 本书架及钥匙串回读通过，再执行界面验证；这不是界面自动续期的实证。
两次界面运行累计 14 个 GET，失败预检及续期回读另各 1 个 GET，
独立授权维护 1 个 POST；账号数据写入 0 次。没有据此推断自然到期原因或真实限频行为。

最终探针与修订后的字段边界检查见
[去敏报告](validation-assets/2026-11-09/native-account-ui-owner-readonly.json)。
其余验证与未完成项继续记于[开发清单](development-roadmap.md)和[本轮验证](validation-2026-11-09.md)。

## 文件缓存、封面与进度组合验收

`verify_persistent_ui.py` 默认离线。显式复用项目授权后，Python 分别核对原生书架／单书资料和 Web 账号，
保留已核对的 Cookie 轮换，再将授权与预期资料通过内存管道传给 Linux 运行工具。
本轮预检观察到原生 HTTP 401，经独立既有工具一次授权续期、139 本书架及钥匙串回读成功后继续；
另有一次经同账号核对的 Web Cookie 轮换保存。两者均不等同于产品自动续期或自然过期验收。

运行工具仅在 `/dev/shm` 的独立 tmpfs 目录创建配置和安装包。授权及账号范围使用匿名描述符；
普通偏好、书籍索引、BookStore、SQLite、封面缩略图和进度缓存走实际产品文件读写，
不替换为内存集合或 `:memory:` SQLite。偏好刷盘仅排除授权材料，其余小型设置保持实际读写。
因此它证明文件后端及跨进程恢复，仍不证明实体磁盘持久性、断电恢复或 Kindle 文件系统。

每种尺寸分别启动两个真正独立的 KOReader 进程：

| 环境 | 首次联网绘制 | 全新进程离线重开 |
| --- | --- | --- |
| 600×800／167 DPI | 139 本／6 分组；前两页、首页及单书资料；12 本封面、11 条进度 | 同书架、分组、资料、偏好、封面及进度一致；零请求 |
| 1264×1680／300 DPI | 同账号书架；相同页面范围；24 本封面、23 条进度 | 同范围一致；零请求 |

每进程实际重绘 4 个页面，共 16 次。资料字段与 Python 独立读取一致，书籍记录再经实际文件载入核对；
SQLite 的文件路径和数据库文件存在性均检查。可见进度逐项对照持久快照，封面逐项检查原生控件及缩略图文件。
最终两次成功验证共 83 个 GET（含 Python 预检），不含此前失败调试、额外只读核对和独立续期。
账号数据写入为零；未保存真实截图或进行人工目视验收。

请求范围仅有两条固定原生 GET，以及来自真实书架的可见书籍进度和匿名封面。
每阶段最多 24 次进度 GET、48 次图片 GET；同一进度地址一次，同一图片地址两次，允许取消后的有限重新读取。
图片跳转仅限原图片的一跳公共 HTTP／HTTPS 地址，排除明显内网地址、账号信息和非默认端口；
每个图片响应仍受原有 3 MiB 限制。授权 API 使用 HTTPS，Cookie 和原生授权头不能混到图片通道。
未指定的 API、POST、额外原生读取和离线阶段的全部请求均拒绝。

早期组合探针的限制过严，误拦截重绘后重新读取和图片跳转；调试轮次不计入通过记录。
已确认非零业务码的进度响应仍停止查询，没有为通过验证放宽产品解析器。
失效授权、轮换预检、图片请求边界和输出脱敏均与产品功能验收分开记录。
本项未改生产 Lua、README、许可证或版本号。

结束前检查生成文件中没有被核对的授权材料，再移除整个临时配置；公开输出仅含固定状态、数量和布尔值。
开发授权仍保留在钥匙串，未随临时配置删除。
每种尺寸只有首页、书架前两页和一本资料的文件缓存组合证据；其余业务页面、全部书架页、真实限频、
休眠／硬件输入、实体 KO2、更多资源格式及完整真实账号验收继续待完成。

```sh
python3 scripts/verify_persistent_ui.py
python3 scripts/test_persistent_ui.py

# 先在隔离环境之外生成候选包；本命令的界面配置会在 tmpfs 中自动创建并移除。
python3 scripts/verify_persistent_ui.py --saved-session --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  python3 /source/scripts/run_persistent_ui_probe.py \
  --koreader /validation/runtime/lib/koreader --candidate /validation/candidate.zip \
  --width 1264 --height 1680 --dpi 300
```

见[文件缓存组合去敏报告](validation-assets/2026-11-09/native-account-file-ui-owner-readonly.json)。
