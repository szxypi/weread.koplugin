# 原生书城：墨水屏授权读取

首页、书城、搜索框、相似书籍列表继续使用 KOReader Lua 控件，正文使用原生 EPUB 引擎。
本次扩展数据通道，不加载网页界面、不执行网页 JavaScript。集中性能优化仍安排在全部功能验收后。

## 真实协议先行

参考 MiuRead 的 `miuread/eink_client.lua`（AGPL-3.0-only，来源见 NOTICE），
先用 `scripts/verify_native_discovery.py` 验证真实响应，才接入 Lua：

| 用途 | 固定 GET | 已核对的参数／响应 |
| --- | --- | --- |
| 搜索 | `/store/search` | `keyword`、`scope=10`、`count=20`、`maxIdx`；根 `books` |
| 为你推荐 | `/book/recommend` | `count=20`、`maxIdx`；根 `books` |
| 相似书籍 | `/book/detailinfo` | `bookId`、`listtypes=2`、`synckey=0`、`count=20`、`maxIdx`；`booksimilar.books` 和 `sessionId` |

调用仅使用墨水屏授权头，隔离 Web Cookie 和 Skill 密钥；HTTPS 使用插件的 CA／SAN 校验。
仅投影有界的书籍展示字段、分页游标和推荐会话，不把原生 `version` 当成 EPUB `bookVersion`。

[真实去敏报告](validation-assets/2026-11-09/native-discovery-owner-readonly.json)：
同一账号的书架回读为 139 本；搜索两页 20＋2 本，相似书籍两页 20＋3 本，游标前进、两页无重复、
相似推荐会话保持一致。Python 与 Lua 对同一真实响应的展示投影一致；KOReader 原生 HTTPS
另行发送 5 个固定只读 GET，独立重复搜索／相似分页检查。没有写入书架、阅读进度或时长。

**真实个性化推荐返回空列表**。只证明空结果契约，不证明真实推荐有内容时的显示或分页；
推荐 20＋6 本的展示／分页使用合成账号验证，不拿最近阅读替代推荐。

## 插件行为

- 搜索、推荐、相似书籍自动优先当前账号的墨水屏授权；无授权时使用已配置的 Skill 密钥。
  两者都缺少时打开授权入口。原有“书架读取方式”仍只影响书架，不作为书城的全局开关。
- 首批读取遇到原生 HTTP 401／403／50x、传输错误或超时时，有 Skill 密钥才可回退一次；401 优先尝试下述一次续期。
  HTTP 429、API 拒绝和无效响应不触发回退。后续页和上一批绑定原通道及授权修订号，不能拼接不同来源。
  刷新列表会从首批重新读取，清除旧游标和推荐会话。授权变化后需刷新或重开列表。
- 网络读取、解析及投影使用独立后台进程和最多 512 KiB 的内存管道；原始 HTTP 响应最多 4 MiB。
  退出页面、取消等待时终止后台请求；关闭种子书详情也立即停止相似书籍请求。
  账号／登录代次／授权变化时丢弃旧结果，旧回调不能关闭新请求的等待窗。
  失败保留当前列表；书城结果保持账号内存缓存，不写入全局设置。
- 分类书单同样在后台读取；分类层级目录也已迁入独立后台进程，并保存公开 SQLite 缓存供未登录离线重开，
  详见[公开分类目录说明](public-category-catalog.md)。
- 原生授权书城读取的 HTTP 401 可复用既有持久化续期流程最多恢复一次，保留原生分页的游标／推荐会话；
  续期后的再次 401 不循环，已有原生分页不会回退其他来源。取消／休眠保留不明回执的待确认标记，
  后续读取不会重放续期。规则见[续期说明](eink-renewal-prototype.md#插件行为)；书城真实失效／限频待验收。

## 本机开发授权

用户允许保留凭证直到整体目标完成，并在本轮重新扫码。`scripts/secure_native_session.py`
把同账号的墨水屏授权保存至 macOS 系统钥匙串的独立项目条目
`org.codex.weread.goal-native-validation`，账号标签为 `P006_kindle_wxread`；
Web 条目 `org.codex.weread.goal-validation` 保留，二者互不覆盖。
保存须通过登录／书架核验，并回读相同字节；复用时核对 Web 条目的账号和原生凭据归属。
私有书名、ID、会话、响应、凭据只经本机进程内存／有界标准输入输出管道比较，不进入报告、截图、临时文件或仓库。
该钥匙串用于开发验证，插件设备端仍使用现有账号绑定的独立授权存储。

默认命令完全离线，不打开钥匙串或网络：

```sh
python3 scripts/verify_native_session.py
python3 scripts/verify_native_discovery.py
# 仅显式复用当前用户已授权的项目条目：
python3 scripts/verify_native_session.py --saved-session
python3 scripts/verify_native_discovery.py --saved-session --native-http --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/discovery_probe.lua /source
```

整体目标验收收尾或用户撤销授权时清理**两个**开发钥匙串条目；当前目标未完成，不执行清理。
原生条目的显式清理入口为 `verify_native_session.py --clear-saved-session`；
Web 条目沿用 `verify_web_source_progress.py --clear-saved-session`。
读取失败、取消或单次测试结束均不删除已授权保存的条目。

后续已在统计接口观察真实 Lua HTTP 401，并完成一次 Python 续期、书架／钥匙串回读及 Lua 统计恢复，
见[原生统计说明](native-statistics-prototype.md)；不作为书城所有真实失效／限频的验收。
实体 Kindle Oasis 2、其他业务码／限频、非空个性化推荐、其他接口、精确同步写后回读仍待验收。
