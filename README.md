# WeRead for KOReader

基于 KOReader 的非官方微信读书插件，面向 Kindle、Kobo 等墨水屏阅读器。项目目标是在保留 KOReader 阅读能力的基础上，逐步实现接近微信读书墨水屏 App 的界面和常用功能。

本项目统一在 [szxypi/weread.koplugin](https://github.com/szxypi/weread.koplugin) 开发。MiuRead 作为功能迁移参考，不另行维护同名副本。

## 开发进展

`main` 当前保留基础插件能力，包括微信登录、书架、书籍搜索、章节缓存、阅读进度与时长同步、划线和想法查看。

第一阶段界面迁移在 [`feature/eink-home-shelf-store`](https://github.com/szxypi/weread.koplugin/tree/feature/eink-home-shelf-store) 分支，见 [PR #1](https://github.com/szxypi/weread.koplugin/pull/1)：

- 首页：最近阅读与离线继续阅读。
- 书架：封面网格、分组及首页／书架／书城导航。
- 书城：个性化推荐、全库搜索、分页和换批。

该阶段尚未合并到 `main`，未发布正式版本。已通过逻辑回归及布局尺寸检查，仍需 KOReader 窗口、Kindle 真机和微信读书账号在线验收。排行榜、分类及进一步的同步能力迁移尚未完成。

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

开发版沿用基线内部版本号，在线更新仍指向上游仓库。试装期间不要使用插件在线更新，以免覆盖本项目的开发改动。

## 登录

在手机微信读书 App 的“我 → 设置 → 微信读书 Skill”中获取个人 API Key，再在插件中使用微信扫码登录。可阅读内容取决于账号的实际权限。

## 开发与反馈

功能迁移和问题修复均提交到本仓库。测试说明见 [docs/testing.md](docs/testing.md)，贡献约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

请勿提交账号凭据、Cookie、个人批注或下载的书籍内容。反馈问题时请说明设备型号、KOReader 版本和复现步骤。

## 来源与许可证

本项目基于 [finlater/weread.koplugin](https://github.com/finlater/weread.koplugin)，并逐步迁移 [MiuRead](https://github.com/miumiupy98-art/miuread-koreader) 的部分功能。感谢原作者与贡献者。

代码采用 [GNU Affero General Public License v3.0](LICENSE)（`AGPL-3.0-only`）。原有版权、第三方组件及迁移代码的来源声明保留在 [NOTICE](NOTICE) 和对应源码中。内置字体的许可证见 [fonts/LICENSE](fonts/LICENSE)。

本项目为非官方社区项目，与微信读书、腾讯及 KOReader 官方不存在隶属或背书关系。
