# 原生章节中的网络图片

资源准备可收集正文及样式表中的网络图片引用。新组件按原始地址去重读取，完成后重新整理正文和样式，将图片放入 EPUB 资源列表；同一地址在正文和样式中重复出现时只请求一次。每张图片最多 8 MiB、合计最多 32 MiB；当前仅接受 HTTPS 的微信／腾讯相关图片域名，不跟随重定向，暂不支持其他图片来源。请求不发送 Cookie、墨水屏授权或其他账号凭据，也不记录图片地址。限频、不可识别图片、请求失败、账号／章节来源变化会停止处理，不自动重试。

合成服务使用实际 KOReader 网络层验证正文与样式重复引用、网络图片嵌入 EPUB 和离线渲染，以及限频、重定向、不支持的域名、异常图片、超限、取消和来源变化；检查模拟服务没有收到登录凭据。独立图片读取测试另覆盖地址实体解码、响应上限和域名边界。

真实账号的一本书、一章含一张网络图片，在 600×800 和 KO2 模拟尺寸分别经过原生章节请求、资源整理及图片下载；无凭据的独立请求读到相同图片内容。两尺寸分别将章节保存到隔离内存文件系统，CRE 找到正文并解码书内图片，随后由禁网的新进程重开、再次解码图片，并确认未附加网页原文坐标元数据。两次临时目录均已清理；凭据没有写入文件，真实正文、图片、地址、书名及编号没有写入仓库或报告。实际屏幕像素、实体 Kindle 和其他书籍仍未验证。[普通尺寸](validation-assets/2026-11-22/native-remote-owner-small.json)、[KO2 尺寸](validation-assets/2026-11-22/native-remote-owner-ko2.json)。

验证前墨水屏授权自然过期，两个独立读取确认 HTTP 401 后执行一次同设备续期；账号、书架及钥匙串回读一致，没有账号数据修改。见[续期记录](validation-assets/2026-11-22/native-remote-renewal.json)。

网络图片已作为默认关闭的[单章下载及预取试验](native-chapter-source.md#单章下载试验)的一部分接入；整书下载路径不变。网络图片域名和响应形式、跨章下载、进度与批注交互、自动恢复及实体设备验收仍需完成。

```sh
luajit spec/native_chapter_remote_spec.lua
python3 scripts/test_native_chapter_remote_reference.py
python3 scripts/test_native_chapter_source_runtime.py --koreader /path/to/koreader
```
