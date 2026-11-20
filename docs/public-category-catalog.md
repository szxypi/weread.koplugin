# 排行榜与分类目录：后台加载和离线重开

书城「分类·榜单」的公开层级目录已迁入独立后台进程。
联网期间可取消、关页、休眠或切换账号，旧结果不会保存或重新打开菜单；
替换过的菜单和旧账号菜单也不能再发起浏览或刷新。
排行榜、主分类、子分类与「该分类全部」仍使用原生 KOReader 菜单，选择后沿用已实现的分类书单分页。

## 保存与失败行为

- 目录成功核对后保存在插件数据目录下的 `bookstore-public.db`，只保存公开 ID、标题、层级、类型及获取时间。
  不包含账号、书籍、搜索词、Cookie 或授权字段，也不写入 `settings/weread.lua`。
  新设置／数据库实例和退出登录后的用户都可重开这份公开目录。
- 有缓存时直接打开，超过 15 分钟或设备时钟回拨时标为「已缓存」，由菜单明确刷新；没有缓存且离线时给出联网提示。
  离线刷新仍保留可用菜单；HTTP 429、网络／解析失败保留旧缓存，不自动重试。
  保存失败可继续浏览本次列表，同时提示该次结果未能保存供离线使用。
- 原始响应最多 4 MiB，内存结果及 SQLite 载荷最多 1 MiB，最多 5,000 个条目；
  标题、ID、层级、数组、状态和时间均有校验。损坏、过大或字段冲突的缓存不作为有效结果。
- 层级目录和未登录时已浏览的公开分类书单保存在 `bookstore-public.db`。
  公开书单只接受分类／榜单查询及匿名公开来源，沿用批次、字段、事务与容量校验。
  已登录时的分类书单仍使用账号自己的数据库；个人搜索、推荐和相似书籍不会进入这份未登录缓存。
  缓存只包含书籍卡片，不包含正文。新进程可恢复最后保存的分类批次，经原生目录重选后可在已保存批次间往返；
  未保存的下一批不显示为可离线浏览，明确刷新才联网重取首批。

## 真实读取先行

公开接口沿用 `scripts/verify_bookstore.py` 已验证的固定合同：
`GET https://weread.qq.com/web/categories?rank=1&synckey=0`。
新增原型默认离线，显式 `--online` 才发送固定匿名 GET，不打开开发钥匙串或附加账号凭据。

[真实去敏记录](validation-assets/2026-11-09/category-catalog-public-readonly.json)：
7 个榜单、22 个主分类、共 201 个条目。Python 与 Lua 对同一响应的层级投影一致；
KOReader 使用插件 HTTPS 再独立读取一次，结果也一致。未发生账号数据写入。
真实响应只在内存和管道中处理，报告不保存标题、类别 ID 或响应正文。

```sh
python3 scripts/verify_category_catalog.py
python3 scripts/test_category_catalog.py
python3 scripts/verify_category_catalog.py --online --native-http --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/category_catalog_preflight.lua /source
```

## 原生验证

实际安装包在官方 KOReader v2026.07.1 Linux ARM64／Xvfb 的 600×800 和
KO2 1264×1680／300 DPI 下通过：原生层级／分页、子进程 HTTP 与界面心跳、
SQLite 新实例回读、未登录离线重开、缓存时间标识、旧／替换菜单回调、429 不重试、
取消／关页／休眠／账号清理、损坏与过大 UTF-8 缓存拒绝、保存失败继续浏览。
同一运行还回归首页、书架可见进度、搜索／相似书籍、分类书单和统计等发现界面流程。

[原生去敏记录](validation-assets/2026-11-09/category-catalog-runtime.json)、
[600 分类层级](validation-assets/2026-11-09/category-catalog-tree-600.png)、
[KO2 离线目录](validation-assets/2026-11-09/category-catalog-offline-ko2.png)。截图全为合成数据。
自动化另覆盖后台故障、账号／会话／时间失效、缓存白名单与 SQL 句柄清理。
这些结果不替代实体 KO2 的网络、按键、休眠或耗电验收；集中性能优化仍在全部功能完成后开展。

```sh
xvfb-run -a python3 scripts/test_discovery_runtime.py \
  --koreader /path/to/koreader --run-dir /path/to/new-directory \
  --width 1264 --height 1680 --dpi 300
```

## 未登录的公开书单与实际页面（2026-11-11）

此前未登录时能在线浏览目录和书单，但书单保存仍依赖账号数据库，重启后无法离线重开。
组件测试已复现此缺口。本次接入有界的未登录分类书单缓存；登录场景保留原有账号隔离。
分类书单的 GET 也新增接收期间 4 MiB 上限、禁止保存响应 Cookie 及去敏错误；不跟随重定向、自动续期或重试。
已有书架、搜索和个人推荐的通道未改动，没有新增账号数据写入入口。

先由独立 Python 匿名读取目录，选择一个排行榜、一个有子分类的主分类及其一个子分类，各读取最多两批。
真实三个入口均返回 20＋20 条；随后两种尺寸各以实际 PluginLoader／FileManager 加载同一候选，
由原生目录选择入口、前往下一批并逐页绘制。另由全新离线进程恢复最后批次、重选三个入口，
在已保存的前后批次及组内页之间往返。界面字段与**各自同一次响应**的独立 Python 投影一致，
离线结果与首次文件 SQLite 快照一致，过期目录回调被拒绝。

600×800 的联网／离线分别为 6／10 次批次核对、24／70 次实际重绘；
KO2 1264×1680／300 DPI 分别为 6／10 次批次核对、12／30 次实际重绘。
120 条来源展示记录会出现在多个页面／离线往返中，不等于 120 本不同书籍。
本轮核对原生控件及封面字段，封面图片下载沿用已有独立验证，没有在这些公开书单场景中重新下载。
没有真实截图或人工目视验收。实际公共缓存仅保存在 Linux tmpfs，目录和书单共用文件 SQLite，
每次结束审计、核对安装包字节后删除临时配置；不打开项目钥匙串或读取账号凭据。

另以合成 HTTP 覆盖排行榜／主分类 20＋6、子分类 15 条、两尺寸的原生宿主／全新离线重开，
拒绝把个人查询存入公开缓存。登录后的既有首页／书架／书城／统计、授权、普通阅读与同步组合继续回归。
固定范围、请求数量及候选／工具哈希见[本批证据](validation-assets/2026-11-11/public-category-books.json)。
实体 KO2 的网络、休眠、文件系统和按键仍待验收，集中性能专项尚未开始。

默认离线检查与匿名实测入口：

```sh
python3 scripts/verify_category_books.py
python3 scripts/test_category_books.py
python3 scripts/verify_category_books.py --online
python3 scripts/verify_category_books.py --online --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation \
  flock -x /validation/weread-native-ui.lock xvfb-run -a \
  python3 /source/scripts/run_public_category_ui.py \
  --koreader /validation/runtime/lib/koreader --candidate /validation/weread-public-category.zip
```
