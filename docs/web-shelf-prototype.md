# 无 Skill 密钥的 Web 书架

## 已实现的行为

扫码后先核对实际账号，再读取可选的 Skill 密钥；未返回密钥或密钥查询失败时仍保存已核对的 Web 登录。
“自动选择”优先使用已保存的墨水屏授权，再尝试常规书架；“常规书架”优先使用已配置的官方接口，
失败或未配置密钥时使用固定的 `GET https://weread.qq.com/web/shelf/sync`。
“墨水屏书架”仍只使用墨水屏授权。三项菜单不增加新的模式。

Web 结果只投影书籍展示字段和分组；每次最多 5,000 本、1,000 个分组，响应最多 4 MiB。
`version` 保存在 `_web_shelf_version`，不当作下载来源的 `bookVersion`。
读取使用捕获的 Cookie 白名单；账号、登录代次、来源选择或 Cookie 发生变化时，丢弃未完成的结果。
子进程和主进程都检查有效性。失败保留已有 SQLite 缓存，不传播响应内容或凭证。

没有密钥时，点开书籍会直接显示书籍页；可查询目录、下载和阅读。
手动调用仍依赖 Skill 的功能时显示授权说明，不反复进入扫码。
首页／书架的当前可见进度也已支持 Web 登录，见 [只读进度核对](shelf-progress-prototype.md)。
书评、部分推荐／搜索和其他官方接口功能仍需要各自的密钥授权，本次没有将它们迁移到 Web 接口。

## 真实账号的只读核对

`scripts/web_shelf_contract.py` 默认只运行离线检查，不访问钥匙串或网络。
显式 `--saved-session` 从用户已授权的项目钥匙串条目复用 Cookie，并首先重新核对账号。
`--native-http` 额外验证真实 KOReader Lua 的登录完成与 Web 书架读取。
它仅允许账号、可选密钥、书架三个固定 GET；不创建二维码或写入书架、进度、时长、笔记。
凭证和完整书架只通过本机内存管道交换，报告只记录数量、状态和布尔值。

```sh
python3 scripts/web_shelf_contract.py
python3 scripts/web_shelf_contract.py --saved-session
# --lua-command 必须最后；以下路径适用于本项目验证容器。
python3 scripts/web_shelf_contract.py --saved-session --native-http --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/web_shelf_probe.lua /source
```

2026-11-08 的[去敏结果](validation-assets/2026-11-08/web-shelf-native-owner.json)：
真实账号未返回 Skill 密钥；Python 与 Lua 都读取到 139 本、5 个分组，完整展示投影一致。
Lua 登录完成、无密钥路径和书架请求通过，3 个 GET，无账号数据写入。
这不代表已在 Kindle 实体设备上验证，或所有 Web 接口均已迁移完成。
开发凭证继续保留在本机系统钥匙串，直到整体目标验收收尾或用户撤销授权。

## HTTPS 连接验证

验证时发现上游运行环境的 LuaSec HTTPS 默认 `verify="none"`，且没有域名校验。
插件现在为自身 HTTPS 请求安装独立传输：验证证书链、有效期和 SAN 域名后才发送 HTTP 请求，
最低 TLS 1.2。域名匹配只接受完整 SAN 或左侧单标签通配；IP 必须匹配 IP SAN；缺少 SAN 时拒绝。
失败会关闭连接，不回退到不验证证书。该实现不修改 KOReader 的全局 HTTPS 行为。
当前传输拒绝代理目标与原站不同的 HTTPS 请求；不实现 HTTP CONNECT 代理。

为不带系统信任库的设备附带 [curl 转换的 Mozilla CA 库](https://curl.se/docs/caextract.html)，
来源日期 2026-11-05、118 个根证书，原始文件、上游 SHA-256 和 MPL 2.0 许可位于 `integrations/ssl/`。
更换信任库时从官方地址下载并核对上游 SHA-256，同时更新许可／来源日期和验证记录。
实际设备时间必须正确；尚未验证实体 KO2 和其 KOReader 版本。

协议依据：[LuaSec 1.3.2 传输](https://github.com/lunarmodules/luasec/blob/v1.3.2/src/https.lua)、
[证书 SAN 接口](https://github.com/lunarmodules/luasec/blob/v1.3.2/src/x509.c)。
[真实传输的合成验收](validation-assets/2026-11-08/web-shelf-tls.json) 覆盖可信、不可信、域名不符、过期和缺少 SAN；
四项拒绝均为 0 个 HTTP 请求，测试没有使用真实凭证。匿名官方服务 HTTPS 读取也通过。

```sh
# 在官方 KOReader 验证环境执行，只有本地合成 CA／服务，不访问账号。
xvfb-run -a python3 scripts/verify_tls_transport.py --koreader /path/to/koreader
```
