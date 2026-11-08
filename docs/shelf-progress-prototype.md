# 首页与书架的 Web 进度读取

## 当前行为

首页和书架只刷新当前可见的普通书籍，已缓存的展示进度保留 120 秒。
已配置官方密钥时优先读取 `/book/getprogress`；一次失败后，该批次剩余书籍改用已核对账号的 Web Cookie。
没有密钥时直接使用 `GET https://weread.qq.com/web/book/getProgress?bookId=...`。
Web 读取与官方查询都捕获当前凭据，不沿用后来登录的账号，不保存响应中的 Cookie。

每个响应最多 64 KiB，错误只保留固定阶段／状态，不记录原始位置、正文或 Cookie。
只将书籍 ID、显示百分比、取得时间和来源写入账号独立的 SQLite 展示缓存。
只返回阅读时长、没有位置的书籍保持未知，并缓存该状态，防止封面重绘反复请求。
遇到服务／权限／限频失败时停止剩余请求，保留有效前缀和旧缓存，同一凭据等待 30 秒后才重试。
账号、登录代次、Cookie 或密钥变化后，主／子进程均拒绝旧批次结果；新凭据不继承旧凭据的失败等待。

同账号、同书籍的本机待上传进度继续优先显示；这条读取链不更新阅读器同步状态，
不写入云端进度／书架／时长／笔记，也不改变现有上传单位或启用精确坐标上传。
Web 登录必须仍然有效；这里不新增续期请求。登录／Cookie 续期使用已有入口。

## 原型与真实账号核对

`scripts/verify_shelf_progress.py` 默认离线，不访问钥匙串或网络。
显式 `--saved-session` 复用用户已授权的本机项目条目，先核对账号，再最多抽取 12 本书；默认 8 本。
若服务端更新了受信任域、路径和白名单中的 Cookie，工具在完成真实读取核对后，
将已验证的新会话保存并回读到同一钥匙串条目，再做可选 Lua 对照。
这样可选对照失败不会丢失已更新的登录状态。条目保留至整体目标验收收尾。

```sh
python3 scripts/verify_shelf_progress.py
python3 scripts/verify_shelf_progress.py --saved-session
# --lua-command 必须最后；路径对应本项目验证容器。
python3 scripts/verify_shelf_progress.py --saved-session --native-http --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/shelf_progress_probe.lua /source
```

2026-11-08 的[真实账号去敏结果](validation-assets/2026-11-08/shelf-progress-owner-readonly.json)：
书架 139 本中抽取 8 本，8 本显示进度均可读取；Python、Lua 模型和原生 HTTPS 的整数显示投影全部一致。
原生 Lua 只发送 8 个固定 GET。凭证、书籍 ID、原始百分比和章节位置只经本机内存管道比较，不进入报告或仓库。
一次单书核对另验证了[新会话的钥匙串保存](validation-assets/2026-11-08/shelf-progress-session-refresh.json)。
这只覆盖当前会话和这 8 本样本，不代表真实过期处理、所有格式或精确云端写入已验收。

## 真实 KOReader 的合成验收

使用打包后的插件、实际后台进程、HTTP、SQLite 和控件；不访问真实账号。
600×800／167 DPI 与 KO2 尺寸 1264×1680／300 DPI 均通过：

- 仅当前可见书籍发起 Web 查询，翻页继续刷新；封面、列表和首页均可显示，离线保留缓存。
- 合成云端为 37%、本机待上传为 83% 时，展示缓存保存 37%，页面继续显示 83%；章号及待上传位置不变。
- 官方接口一次失败后，本批次只再用 Web；429 后停止剩余请求、立即重试受限，新 Cookie 可重新验证。
- 实际请求中更换 Cookie，旧子进程结果不会覆盖 SQLite。
- 前后对比没有新增云端进度写入；测试恢复原有合成登录配置。

截图：[无密钥封面书架](validation-assets/2026-11-08/web-progress-shelf.png)、
[无密钥首页](validation-assets/2026-11-08/web-progress-home.png)。
实体 KO2 的网络、按键、休眠唤醒和屏幕表现仍待验证。
