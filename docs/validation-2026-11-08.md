# 2026-11-08 开发阶段验证

本记录对应开发分支的独立更新通道和真实运行环境建设，不是正式发布验收。
剩余功能见 [开发清单](development-roadmap.md)。

## 实现与修正

- 更新元数据和安装包只从 `szxypi/weread.koplugin` 获取。
- 清除旧仓库的缓存更新信息；下载包及校验文件必须匹配本仓库和目标版本。
- 本仓库尚无正式 Release，GitHub 返回 404 时提示“尚未发布”，不当作普通网络故障。
- 修复首页与书城标题显示为禁用灰色的问题。
- 新增真实运行脚本；原有阅读与更新脚本不再依赖发行包没有包含的单元测试框架。

## 实际执行结果

| 项目 | 结果与覆盖范围 |
| --- | --- |
| Lua 单元／组件回归 | PASS：76 组，包括更新缓存隔离、外部包拒绝、版本匹配、404／503 区分 |
| Luacheck | PASS：171 文件，0 警告、0 错误 |
| 命名空间、Python 编译、差异格式 | PASS |
| Python 合成 HTTP 测试 | PASS：5 组 |
| 真实插件初始化 | PASS：官方 KOReader v2026.07.1、真实控件／字体／SQLite |
| 首页／书架／书城 | PASS：候选 ZIP 安装后，空页面、最近阅读、分页、列表／封面切换、搜索／推荐、关闭和账号清理 |
| 三种显示配置 | PASS：600×800/167 DPI、800×600/167 DPI、1072×1448/300 DPI，原生 BB8 灰度模拟 |
| 本地合成 HTTP + 真实 Lua Client | PASS：推荐首批与末批、搜索、书架、封面下载及缩略图缓存 |
| 阅读主链路 | PASS：真实 PluginLoader → Client/Content → EPUB → ReaderUI → 第二页 |
| 整本下载 | PASS：真实后台下载器与事件循环；六章正文、图片和脚注；ZIP 与章节完整性检查 |
| 更新主链路 | PASS：真实子进程、说明滚动、固定按钮、提醒持久化、SHA-256 失败拒绝、重试安装和旧目录备份 |
| 真实账号读写 | 未执行：没有测试授权环境 |
| Kindle 硬件 | 未执行：尚无连接设备；残影、真实触摸、按键、休眠与耗电仍待验证 |

界面测试通过控件回调执行操作，不等于对每个触摸坐标、手势或按键完成端到端验收。
合成 HTTP 服务器不会转发到微信读书，故不能证明线上接口当下仍接受相同请求。
更新测试替换 HTTP 读取边界为本地包，真实执行其余下载后的校验和安装步骤。

## 环境与复验

主机通过 OrbStack 运行 `weread-validation` 容器，基础镜像为 Ubuntu 24.04 ARM64。
使用官方 `koreader-linux-arm64-v2026.07.1.tar.xz`，未从源代码重新构建。
安装包、隔离设置、请求日志、截图及运行日志位于项目外层 `.validation/`：

- `bw-600/`、`bw-landscape/`、`bw-large/`：灰度页面验证。
- `reader-core/`：阅读、翻页与整本下载验证。
- `updater-candidate/`：更新安装与恢复验证。

Linux 环境依赖 SDL、Xvfb、xauth、zip/unzip、Python 3 和 git。
容器中的源码挂载为只读；测试只写独立目录，不访问日常阅读配置。

```sh
xvfb-run -a python3 scripts/test_discovery_runtime.py \
  --koreader /path/to/runtime --run-dir /path/to/new-discovery-run
xvfb-run -a python3 scripts/mock_weread.py --smoke --port 0 \
  --koreader /path/to/runtime --run-dir /path/to/new-reader-run
xvfb-run -a python3 scripts/test_updater_simulator.py \
  --koreader /path/to/runtime --run-dir /path/to/new-updater-run
```

## 实际截图

封面与正文均为合成测试数据。以下截图由真实 KOReader 输出。

![首页](validation-assets/2026-11-08/home.png)

![横屏书城搜索](validation-assets/2026-11-08/store-landscape.png)

![下载的合成 EPUB 第二页](validation-assets/2026-11-08/reader.png)
