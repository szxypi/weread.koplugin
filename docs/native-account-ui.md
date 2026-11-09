# 真实账号的原生文字界面只读验证

`scripts/verify_native_ui.py` 默认离线；显式复用已授权保存的项目会话后，
先由 Python 读取一次书架和一本同架书籍的资料，再让打包插件独立读取并显示真实数据。
本项补充已通过的接口投影、合成 HTTP、原生控件和缓存验证，不修改产品功能或默认设置。

## 本轮实际范围

官方 KOReader v2026.07.1 Linux ARM64／Xvfb，KO2 的 1264×1680／300 DPI、灰度缓冲区。
真实书架 139 本，界面分组 6 项（含未分组）；实际显示列表第一页和第二页、首页、
同书资料、搜索、相似书籍和个性化推荐，共 7 次原生重绘。
搜索和相似首批各 20 本，真实个性化推荐为空；空列表同样完成原生绘制。
详情保存及控件字段与 Python 独立读取投影一致，工作进程读取期间主界面定时回调可执行。

本项关闭封面下载和可见进度查询，不证明这两条真实账号链路已完成界面验收。
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
