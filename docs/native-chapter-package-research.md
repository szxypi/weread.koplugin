# 原生章节包与网页正文的只读对照

为迁移 MiuRead 的 E-Ink 章节下载，新增独立的只读验证工具。工具使用当前账号的墨水屏授权读取书架、资料和完整目录；只选取目录中明确免费或已购买的章节，并以关闭自动购买的参数请求一次章节包。密钥、包和正文仅在进程内存中处理，不创建章节文件或输出账号、书名、章节编号及正文。网页对照同样使用当前账号，且先确认账号身份。

2026-11-22 分别从书架中三个互不重叠的范围选取一本书的一章：三个原生包均成功解密并提取正文；与网页同书同章对照，两份正文逐字节一致，第三份字节不同但去除空白后的可见文字一致。这是三个样本的观察，不能证明其他章节一致，也不能将文字一致视为精确位置或划线范围兼容。原生正文尚未用于正式下载，已有 Web 来源的坐标、进度及批注行为不变。

第一份真实章节包包含一个使用 `..` 相对路径的共享图片；最初只读工具忽略该图片，后续 Python 与 KOReader Lua 解析器均将其作为内存数据读取并生成独立的内部名称，没有按包内路径写文件。该包还有一个无法识别图片格式的条目，解析结果明确报告；另外两份样本没有此类条目。图片格式识别不等于图片可完整解码或正文引用均已匹配。正文和样式引用、跨章节续传、账号切换、失败回退、不同来源的坐标隔离、完整 KOReader 下载与实体设备仍须验证后才能接入下载流程。本地模拟覆盖加密 ZIP、口令校验、清单重复键／大编号拒绝、章节排序、异常路径、未识别图片、重复／缺失正文、付费限制和请求范围；真实失败及最终结果只保存去敏元数据。

固定结果：[样本一](validation-assets/2026-11-22/native-chapter-comparison-1.json)、[样本二](validation-assets/2026-11-22/native-chapter-comparison-2.json)、[样本三](validation-assets/2026-11-22/native-chapter-comparison-3.json)。测试仅请求已有权限的正文，无账号数据修改或授权请求；这些结果不能证明端上图片已显示或服务端的所有历史未改变。

随后在官方 KOReader 2026.07.1 Linux ARM64 的 LuaJIT 环境中使用同一批次的三份真实章节包，与独立 Python 解密器逐项比较正文、样式及可识别图片的内容摘要、类型和相对路径类别；三份均一致。原文、图片及凭据只通过内存管道传入 KOReader，未保存在文件或公开记录。样本一明确报告一个不能识别的图片条目，其他两份没有；[Lua 样本一](validation-assets/2026-11-22/native-chapter-lua-1.json)、[样本二](validation-assets/2026-11-22/native-chapter-lua-2.json)、[样本三](validation-assets/2026-11-22/native-chapter-lua-3.json)。这一对照仅验证解包和模型，不代表图片已在阅读器中显示，也不授权把正文当作 Web 的精确坐标来源。

```sh
python3 scripts/test_native_chapter_package.py
python3 scripts/verify_native_chapter_package.py
# 显式使用项目钥匙串，只读检查书架的指定范围
python3 scripts/verify_native_chapter_package.py --saved-session --book-offset 0
# 在 KOReader 运行环境中执行合成包验证
python3 scripts/test_native_chapter_archive_runtime.py --koreader /path/to/koreader
```
