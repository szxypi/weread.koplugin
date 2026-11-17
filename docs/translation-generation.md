# 官方译文请求的单章计划

当前阶段补齐独立 Python 请求契约、不可重放意图与只读样本选择。
**尚未发送真实生成请求，也未接入原生菜单中的译文获取／生成。**
已有译文的原生双语显示继续见[显示说明](official-translation-prototype.md)。

## 来源与单章范围

请求字段参考 MiuRead 提交 `c1893562aa25a870b8dd076d7be062a3348f823e` 的
[eink_client.lua](https://github.com/miumiupy98-art/miuread-koreader/blob/c1893562aa25a870b8dd076d7be062a3348f823e/miuread.koplugin/miuread/eink_client.lua) 与
[translation_generation.lua](https://github.com/miumiupy98-art/miuread-koreader/blob/c1893562aa25a870b8dd076d7be062a3348f823e/miuread.koplugin/miuread/translation_generation.lua)，
Copyright (C) 2026 MiuRead contributors，AGPL-3.0-only。
Python 重新实现单章计划及回执解释，没有迁移上游自动续期和重复请求流程。

准备只接受明确的付费会员、EPUB、同账号、目录中唯一且明确免费／已购买的有正文章节。
计划绑定书号、章号、来源版本、译文版本、当次授权，以及目录、原文、两端位置／字段存在性、逐书计数和书架摘要。
会员身份不把未知价格变成免费；原文必须实际存在；正文已有译文时不创建“缺失译文生成”计划。
`hasTranslated`／译文字数仍只是元数据，不代替译文内容核对。

纯模型生成的请求只包含当前章，`reference.texts` 明确为空数组，`freeTrial=0`。
不携带下一章、购买、试用或阅读时长请求。
模式修改 `GET /trans/pdfepub` 与生成 `POST /en/bookread` 在语义上都是服务端操作；只读准备器没有这两个网络通道。

## 回执与不可重放

独立钥匙串范围最多领取一次模式操作和一次生成请求；先持久保存领取，再允许调用方派发。
原始有界 JSON 回执先保存，之后才解释成功。未知／拒绝／错书回执保持可读，不批准后续操作；
进程中断、回执丢失或重复调用均不重新领取。
两份回执及计划总大小受实际 64 KiB 钥匙串边界限制，单份回执最多 24 KiB。

模式操作必须明确 `succ=true/1`；存在的书号／账号必须与计划一致。
生成状态区分等待、已停止但不可用、版本就绪；错误码、错误章号、重复章号、版本倒退、未知类型或冲突包裹均不接受。
版本就绪要求明确停止以及当前章正译文版本，仍必须另行取得实际非空译文才能确认下载。
当前单次范围不提供轮询重发或未知结果恢复额度，真实状态协议验证后再实现有界接续。

## 当前验证

新增 34 项测试覆盖付费／章节权限、原文与译文判断、完整载荷、字段类型、归属、回执保存顺序、
竞争旧回执、损坏记录、保存失败、大小边界及只读网络白名单。
完整 Python 回归为 137 个测试模块／1763 项，零跳过；CI 新增完整发现运行，避免新增测试遗漏在逐项列表外。
生产 Lua 与安装包字节未变，既有正常阅读、位置同步和历史采集范围不变。

2026 年 11 月 17 日真实只读抽查：会员状态可核对，两本公开英文书的八个明确免费章节均取得了现成译文，
无空正文样本；最终账号回读成功。未找到缺失译文样本，没有保存新生成意图，也没有模式、生成、试用、购买、账号数据或授权请求。
这项结果证明了现成译文可读取，不能作为缺失译文生成协议通过的证据。
[固定结果记录](validation-assets/2026-11-17/translation-generation.json)。

默认离线：

```sh
python3 scripts/verify_translation_generation.py
python3 scripts/test_translation_generation.py
```

显式只读寻找样本，正文和身份只留在内存：

```sh
python3 scripts/verify_translation_generation.py --saved-session
```

`--prepare` 只在两轮原文、目录、位置、计数及书架一致后保存不可覆盖计划；
`--dry-run` 重新核对已经准备的同一计划，均不能派发模式或生成操作。
后续仍需新的缺失译文样本、真实 Python 协议验证、原生获取／生成与缓存安装，以及实体 KO2 验收。
