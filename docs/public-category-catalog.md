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
- 持久缓存范围是**分类层级目录**。分类书单仍沿用现有后台分页与内存状态；
  本阶段没有把书单、搜索或个人推荐变成持久离线书库。

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
