# WeRead for KOReader

基于 KOReader 的非官方微信读书插件，面向 Kindle、Kobo 等墨水屏阅读器。项目目标是在保留 KOReader 阅读能力的基础上，逐步实现接近微信读书墨水屏 App 的界面和常用功能。

本项目统一在 [szxypi/weread.koplugin](https://github.com/szxypi/weread.koplugin) 开发。MiuRead 作为功能迁移参考，不另行维护同名副本。

## 开发进展

`main` 当前保留基础插件能力，包括微信登录、书架、书籍搜索、章节缓存、阅读进度与时长同步、划线和想法查看。

第一阶段界面迁移在 [`feature/eink-home-shelf-store`](https://github.com/szxypi/weread.koplugin/tree/feature/eink-home-shelf-store) 分支，见 [PR #1](https://github.com/szxypi/weread.koplugin/pull/1)：

- 首页：最近阅读与离线继续阅读；长按“书城”可选择搜索微信读书、书架或本机已保存笔记，也可从首页快捷设置选择搜索范围或屏幕方向。
- 书架：封面网格、云端分组浏览、本机分组管理及首页／书架／书城导航；本机分组支持普通书与个人导入书，不与微信读书同步，书名排序支持大小写与全角归一，并保留置顶和同名顺序。
- 书架筛选：可按已知进度筛选未读和在读，并与已下载筛选组合；进度取自可能过期的本机缓存，未知值不会进入结果，可在筛选菜单主动更新全书架进度。它不代表服务端的「开始阅读」标记，详见[说明](docs/shelf-groups-and-popups.md#按进度筛选)。
- 云端书架：可离线保存单本书或公众号的加入、移除请求；联网后核对并同步，详见[书架成员说明](docs/cloud-shelf-membership.md#离线修改)。
- 云端置顶：书籍状态中可置顶或取消普通书及个人导入书；结果不明时可重新核对，见[云端置顶说明](docs/cloud-pins.md)。
- 离线修改：从首页快捷设置、书架选项或插件菜单集中查看待同步／待核对的书架及读完标记，并进入状态页处理。
- 阅读进度：阅读快捷菜单可查看当前章节或文件进度，通过进度条、±10% 或页码输入跳转，并进入上一章／下一章。原生墨水屏章节在目录字数可核对时也显示本机全书估算。已开启打开时拉取进度且来源可核对的导入书在离线阅读后重新联网时，会先比较并提示选择本机或云端位置。
- 章节目录：点击「查找章节」按标题筛选，已载入的目录支持离线搜索。同名章节按原目录顺序分别列出，保留各自的缓存状态。
- 阅读设置：在阅读快捷菜单选择设备字体、字号、行距、字重和页边距；可分别确认将字体设置或边距设为 KOReader 全局默认，供新章节和其他未单独设置的书籍使用，见[排版说明](docs/reader-typography.md)。
- 墨水屏章节资源试验：下载设置可分别为单章／预取和整书开启，均默认关闭，并需要启用图书图片下载和有效的墨水屏授权。只有两种来源的正文完全一致时才使用墨水屏章节及资源；否则沿用原下载方式。试验需要额外网络请求，见[说明](docs/native-chapter-source.md#单章下载试验)。
- 墨水屏章节缓存：书籍详情可预览并清理未使用的章节，保留本机笔记、继续阅读和时长记录引用的副本；中断后可重新进入清理，详见[原生阅读说明](docs/native-direct-reading.md)。
- 页面显示：阅读快捷菜单可调整 KOReader 状态栏、进度条和页码等项目；设置对 KOReader 全局生效，见[状态栏说明](docs/reader-display.md)。
- 延时截图：从首页快捷设置或阅读快捷菜单设置 5、10、15 秒后截图，可取消或绑定 KOReader 手势，图片由 KOReader 保存。
- 读完标记：可在书架状态中离线保存修改；联网后核对并同步，结果不明时保留记录供核对，详见[说明](docs/finished-mark.md#离线修改)。
- 书城：公开榜单与分类、搜索、个性化推荐、分页和离线浏览已保存批次；最近搜索词可重新搜索、单独移除或清空，登录后按账号保存在本机。封面下显示作者以及可用的评分和推荐理由。
- 书籍快捷操作：在首页、书架或书城长按书籍，可阅读、查看详情或管理云端书架；书架长按还可为该书选择或新建本机分组；已在书架中的书籍还可直接修改读完标记。封面和列表视图均支持，书籍详情页也提供状态管理入口。
- 阅读语言：支持显示已有译文，并可将本章、最多连续三个章节或整本书的已有译文保存为独立离线副本；本章官方译文请求入口为试验功能，真实生成尚待验证，详见[译文说明](docs/translation-fetch.md)和[请求说明](docs/translation-generation.md)。
- 阅读笔记：从“我的笔记本”集中查看、搜索和排序有笔记的书籍，进入各书的云端划线、书签和想法；支持查看和批量离线保存已识别的想法图片、跨书搜索已保存笔记，以及离线查看和恢复不同书籍的想法草稿。已下载原生章节有完整原文时，可离线选区新建私密想法草稿，联网提交前会重新核对来源，详情见[我的笔记本](docs/notebook-catalog.md)和[选区说明](docs/native-direct-selection.md)。
- 章节想法：选择匹配章节时可快捷添加本章起最多十章，或跨页选择起止范围；保留已有勾选，也可清空本次选择，实际获取仍需单独点击确认，见[章节划线与想法](docs/native-annotations.md)。
- 书评：可查看并翻页阅读公开书评和可识别的书评图片；墨水屏通道已加载的最新书评、已打开图片和公开回复支持离线查看，阅读中的公开想法回复也可缓存，详情见[书评说明](docs/book-reviews.md)。
- 笔记导出：将本机保存的云端划线、书签和想法导出为 Markdown 或 JSON，详见[导出说明](docs/cloud-notes-export.md)。
- 书摘卡片：从阅读器选区或已保存的云端划线、想法预览不同模板，保存为本机 PNG，或通过同一局域网扫码取图；手机与真机验收仍在进行，见[说明](docs/excerpt-cards.md)。

该阶段尚未合并到 `main`，未发布正式版本。部分功能已通过 KOReader 模拟环境及真实账号验证；更多书籍、网络状态和 Kindle 真机仍需验收。各功能的实现和验证边界见[开发与验收清单](docs/development-roadmap.md)。

## 开发版试装

建议使用 KOReader 2026.03 或更高版本。

1. 从界面迁移分支获取源码，或使用该分支生成的测试安装包。
2. 备份已有插件，将完整的 `weread.koplugin` 目录放入 `koreader/plugins/`。
3. 完整重启 KOReader，进入“工具 → 微信读书 → 微信读书首页”。

自行打包：

```sh
git clone --branch feature/eink-home-shelf-store https://github.com/szxypi/weread.koplugin.git
cd weread.koplugin
bash scripts/package_release.sh dist/weread.koplugin-eink-ui-dev.zip
```

开发版沿用基线内部版本号。插件的在线更新只检查本项目的正式 Release；当前尚未发布正式版本，开发分支的后续改动需要重新打包安装。

连续书架列表的墨水屏性能优化及模拟测试见[性能说明](docs/eink-performance.md)；实体 Kindle 测量仍待完成。

## 登录

在插件中使用微信扫码登录。部分功能可使用手机微信读书 App“我 → 设置 → 微信读书 Skill”中的个人 API Key；公开书目浏览不需要登录。可阅读内容取决于账号的实际权限。

## 开发与反馈

功能迁移和问题修复均提交到本仓库。测试说明见 [docs/testing.md](docs/testing.md)，贡献约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

请勿提交账号凭据、Cookie、个人批注或下载的书籍内容。反馈问题时请说明设备型号、KOReader 版本和复现步骤。

## 来源与许可证

本项目基于 [finlater/weread.koplugin](https://github.com/finlater/weread.koplugin)，并逐步迁移 [MiuRead](https://github.com/miumiupy98-art/miuread-koreader) 的部分功能。感谢原作者与贡献者。

代码采用 [GNU Affero General Public License v3.0](LICENSE)（`AGPL-3.0-only`）。原有版权、第三方组件及迁移代码的来源声明保留在 [NOTICE](NOTICE) 和对应源码中。内置字体的许可证见 [fonts/LICENSE](fonts/LICENSE)。

本项目为非官方社区项目，与微信读书、腾讯及 KOReader 官方不存在隶属或背书关系。
