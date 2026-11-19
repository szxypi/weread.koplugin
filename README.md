# WeRead for KOReader

基于 KOReader 的非官方微信读书插件，面向 Kindle、Kobo 等墨水屏阅读器。项目目标是在保留 KOReader 阅读能力的基础上，逐步实现接近微信读书墨水屏 App 的界面和常用功能。

本项目统一在 [szxypi/weread.koplugin](https://github.com/szxypi/weread.koplugin) 开发。MiuRead 作为功能迁移参考，不另行维护同名副本。

## 开发进展

`main` 当前保留基础插件能力，包括微信登录、书架、书籍搜索、章节缓存、阅读进度与时长同步、划线和想法查看。

第一阶段界面迁移在 [`feature/eink-home-shelf-store`](https://github.com/szxypi/weread.koplugin/tree/feature/eink-home-shelf-store) 分支，见 [PR #1](https://github.com/szxypi/weread.koplugin/pull/1)：

- 首页：最近阅读与离线继续阅读；长按“书城”可选择搜索微信读书、书架或本机已保存笔记，也可从首页快捷设置进入搜索范围选择。
- 书架：封面网格、分组及首页／书架／书城导航。
- 读完标记：可在书架状态中离线保存修改；联网后核对并同步，结果不明时保留记录供核对，详见[说明](docs/finished-mark.md#离线修改)。
- 书城：公开榜单与分类、搜索、个性化推荐、分页和离线浏览已保存批次。
- 书籍快捷操作：在首页、书架或书城长按书籍，可阅读、查看详情或管理云端书架；已在书架中的书籍还可直接修改读完标记。封面和列表视图均支持。
- 阅读笔记：从“我的笔记本”集中查看、搜索和排序有笔记的书籍，进入各书的云端划线、书签和想法；支持跨书搜索本机已保存的笔记及离线浏览缓存，详情见[我的笔记本](docs/notebook-catalog.md)。
- 书评：可查看并翻页阅读公开书评；墨水屏通道已加载的最新书评和公开回复支持离线查看，阅读中的公开想法回复也可缓存，详情见[书评说明](docs/book-reviews.md)。
- 笔记导出：将本机保存的云端划线、书签和想法导出为 Markdown 或 JSON，详见[导出说明](docs/cloud-notes-export.md)。

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

## 登录

在插件中使用微信扫码登录。部分功能可使用手机微信读书 App“我 → 设置 → 微信读书 Skill”中的个人 API Key；公开书目浏览不需要登录。可阅读内容取决于账号的实际权限。

## 开发与反馈

功能迁移和问题修复均提交到本仓库。测试说明见 [docs/testing.md](docs/testing.md)，贡献约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

请勿提交账号凭据、Cookie、个人批注或下载的书籍内容。反馈问题时请说明设备型号、KOReader 版本和复现步骤。

## 来源与许可证

本项目基于 [finlater/weread.koplugin](https://github.com/finlater/weread.koplugin)，并逐步迁移 [MiuRead](https://github.com/miumiupy98-art/miuread-koreader) 的部分功能。感谢原作者与贡献者。

代码采用 [GNU Affero General Public License v3.0](LICENSE)（`AGPL-3.0-only`）。原有版权、第三方组件及迁移代码的来源声明保留在 [NOTICE](NOTICE) 和对应源码中。内置字体的许可证见 [fonts/LICENSE](fonts/LICENSE)。

本项目为非官方社区项目，与微信读书、腾讯及 KOReader 官方不存在隶属或背书关系。
