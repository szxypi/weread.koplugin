# CI 工具安装与扫描错误修复

提交 `dce14b6` 的 [GitHub CI](https://github.com/szxypi/weread.koplugin/actions/runs/43066084846) 全部通过。
此前多次失败发生在 Ubuntu 软件源 DNS 解析阶段，代码检查未开始；这些历史失败记录保留。

## 安装方式

Ubuntu 24.04 托管环境保留不变，使用镜像已有的 Python、GCC、make、git 和 SQLite。
LuaJIT、Luacheck、LuaFileSystem、argparse 从各自上游 GitHub 的固定提交构建或安装；
ripgrep 使用固定版本的上游 Linux musl 发布包。提交、版本和 SHA-256 均记录在
[工具锁定清单](../scripts/ci_toolchain.lock.json)，支持 x86_64 与 ARM64。

所有输入先校验摘要，再解包和构建；只允许受限的上游 HTTPS 地址与重定向。
解包拒绝目录越界、链接、重复路径、多根目录及超限归档。
工具安装到作业临时目录的新前缀，不修改系统软件源或使用管理员权限；已有前缀不能覆盖。
安装保留各工具的许可证，并实际检查 LuaJIT／FFI／SQLite、Luacheck 依赖版本和 ripgrep PCRE2。
只有全部成功才写安装记录并将工具目录加入后续检查路径。
`--archives` 模式只使用指定的本地归档，仍检查摘要，缺失时不回退联网。

LuaJIT 的构建方式与 Luacheck 的依赖来自其[官方安装说明](https://luajit.org/install.html)及
[上游固定版本依赖声明](https://github.com/lunarmodules/luacheck/blob/cc089e3f65acdd1ef8716cc73a3eca24a6b845e4/rockspecs/luacheck-1.2.0-1.rockspec)。
托管镜像的编译工具见 [Ubuntu 24.04 镜像清单](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md)。

## 扫描失败处理

修复前已用退出码 2 的替代搜索工具复现：命名空间检查和敏感信息检查都会把工具错误当作未找到匹配而通过。
现在严格区分找到匹配、无匹配和执行错误；工具报错会使检查失败。
原有扫描范围、表达式及其余检查均保留，没有删除或跳过步骤。
新增 13 项离线检查覆盖下载摘要、离线边界、解包、安装隔离及这两个失败路径。

## 验证范围

- 本机隔离 Debian ARM64 环境：两次全新前缀源码构建通过，第二次另核对五个工具的七份上游许可证。
- Ubuntu 24.04 ARM64：新工具运行当前工作流的全部检查通过。
- GitHub Ubuntu 24.04 x86_64：实际联网下载、源码编译、安装检查及全部工作流步骤通过。
- 93 份 Python／1,131 项零跳过，222 组 Lua；623 个静态文件零警告／错误，625 个 Lua 语法、
  288 个 Python 编译、四时区、命名空间、TLS、打包、版本说明与敏感信息检查通过。
- 对比前一提交，原有 29 个步骤全部保留；增加工具边界测试，仅替换安装方式并加强扫描错误处理。
  本批没有修改生产插件文件、README、许可证、NOTICE、Changelog、入口或版本。
- 本批未访问微信读书接口，没有账号数据或授权 POST。测试意图均已清理，开发登录继续保留在钥匙串。

固定证据见[本批记录](validation-assets/2026-11-12/ci-toolchain.json)。
本项证明构建与检查链路恢复，不增加实体 KO2、断电或性能验收结论；整体功能清单仍在进行。
