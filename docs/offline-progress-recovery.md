# 离线阅读进度与重连核对

正常书籍在离线、尚未核对云端位置或关闭自动同步时，仍保存本机阅读位置。
实际翻页后的待同步记录在保存设置、休眠、断网和关书时写入书籍文件，按当前账号绑定；
不在每次翻页时写盘。首页与书架优先显示该本机进度，旧云端展示缓存不会覆盖它。
只打开书籍而没有移动，不会新建待同步记录。

本机保存不授予上传权限，也不自动开启同步。启用「打开时拉取进度」后，
重新联网会重建已耗尽的离线读取流程，先比较当前页面和云端位置；
关闭该选项时仍需手动同步。断网撤销尚未执行的上传、旧读取和旧冲突决定，
关闭上报许可。重复联网事件不会重复当前读取或冲突选择。
正在保留的只读原文目标不会被此重连流程替换。

选择本机位置沿用已有进度上传协议。选择云端位置时，立即撤销旧排队上传，
但等原生跳转成功后才清除本机待同步记录。引擎跳转失败、目标章节下载失败或取消，
均保留本机记录并关闭上传许可；跨阅读器打开目标章后成功应用位置，才提交清除。

## 验证

- 修改前用组件测试复现：离线翻页后关书仍保存旧位置，并且没有待同步记录；
  另复现失败／取消云端跳转会过早删除本机记录。
- `progress_sync_spec.lua` 增加 49 项检查，合计 319 项；全部 155 组 Lua、34 套共 351 个 Python 测试通过。
- 官方 KOReader v2026.07.1 Linux ARM64／Xvfb 的 600×800 和 1264×1680／300 DPI，
  各用三个进程完成插件选书阅读、离线翻页、保存／休眠、首页显示本机进度、
  再次启动恢复位置和待同步记录、重连只读核对及两种冲突选择。
- 离线进程新增 HTTP 请求为零；选择前写请求为零。选择本机后只有一组进入阅读会话及进度更新
  （共两个零时长 POST），模拟服务回读一致；随后选择云端只跳转，保存／关书不重建旧待同步记录或再次上传。

以上为合成账号和实际 HTTP、原生控件、CRE 及文件保存验证。
联网状态通过测试入口模拟，截图中的系统 Wi-Fi 状态不代表真实断网；未访问真实账号或钥匙串。
现有上传仍使用既有字数／百分比映射，不将只读原文坐标作为已验证的上传坐标。
真实账号精确上传与多设备回读、实际网络切换和实体 KO2、异常断电及文件系统故障仍待验收。

复验命令：

```sh
xvfb-run -a python3 scripts/test_discovery_runtime.py --reading-flow --offline-progress \
  --koreader /path/to/runtime --run-dir /path/to/new-test-directory
```

KO2 尺寸追加 `--width 1264 --height 1680 --dpi 300`。每次使用新目录。
去敏结果见[运行报告](validation-assets/2026-11-09/offline-progress-runtime.json)和[本轮验证](validation-2026-11-09.md)。


## 真实账号的断网重连与选择云端

2026-11-22 在官方 KOReader 模拟器的 600×800 和 KO2 尺寸，使用真实账号中的一册普通 TXT 验证只读恢复。通过插件书架进入原生阅读器后，模拟网络断开并实际翻页，独立确认翻页后的原文位置在当前页面；检查点及待同步位置在保存、休眠和唤醒后仍保留。断网阶段的插件请求全部拦截，并核对请求计数没有变化。

模拟重连触发原生云端比较，重复发送联网事件没有打开第二个选择窗口；选择前仍保存本机待同步位置。选择微信读书进度后，插件后台核对来源、跳转至云端精确原文位置并清除旧待同步位置。随后全新离线进程重开，验证位置恢复且零请求。宿主在验收前后独立核对 Web 与墨水屏的云端位置、摘要、时长计数、书架、目录和原文，结果一致；真实账号数据修改和验收期间的授权 POST 均为零。

同样的流程先在两种尺寸使用封闭合成服务验证，旧版手动选择流程也已回归。加强位置断言的首轮合成尝试因验证工具错误地要求普通页面存在保留锚点而超时，修正为直接核对该页的原文位置后通过；没有访问真实账号。真实账号初次准备时墨水屏接口返回 401，未进入阅读器；随后一次凭据续期核对同账号和书架并保存回读，再执行上述只读验收。

去敏记录：[普通尺寸](validation-assets/2026-11-22/offline-reconnect-owner-600.json)、[KO2 尺寸](validation-assets/2026-11-22/offline-reconnect-owner-ko2.json)、[首次 401](validation-assets/2026-11-22/offline-reconnect-preflight-401.json)、[授权续期](validation-assets/2026-11-22/offline-reconnect-native-renewal.json)，以及合成账号的[普通尺寸](validation-assets/2026-11-22/offline-reconnect-mock-600.json)和 [KO2 尺寸](validation-assets/2026-11-22/offline-reconnect-mock-ko2.json)。验收使用软件模拟联网变化，未模拟实体 Wi-Fi 或断电；本轮只验证选择云端分支，不代表真实重连后选择本机位置上传、多设备并发或实体 KO2 已验收。


## 导入书重连后的本机位置选择

支持来源核对的 `CB_` 导入书在开启「打开时拉取进度」后，若当前账号有离线保存的待同步位置，重连会先读取并比较云端位置，再显示本机／云端选择。重复联网事件不会重复弹窗或发送请求；只有明确选择本机后，才进入既有来源核对、一次同步与回读流程。尚未确认的旧发送、无法确认账号归属的记录及其他账号的记录不会通过这个重连入口重发。没有本机待同步记录的普通自动打开仍按原规则处理。

2026-11-22 用一份新导入的自造多页 EPUB 在两种模拟屏幕完成真实账号验证：分别断网翻页、保存本机位置、重连选择本机、原生发送并由 Web 与墨水屏两端独立读回；每种尺寸还完成全新进程离线重开。两次重连共四个进度请求，阅读时长为零，测试书另有一次首次位置请求。未修改既有书籍；测试书最后单次移除，新进程两轮读取确认原书架成员、可见标记和分组恢复。服务端历史和最近阅读排序不保证恢复。联网变化由软件模拟，真实 Wi-Fi、多设备并发、其他正文和实体 KO2 仍待验收。

首次尝试在首次位置确认后停止：测试正文有重复段落，仅按位置后的文字检查无法唯一识别目标，重连写入额度仍未领取。独立检查改用前后文确认唯一坐标后，以零写入预演及只读状态核对接续，未重复导入或首次位置写入。两次重连及回读通过后，工具复用了限单次读取的来源检查器，导致清理前复核失败；因此另用全新只读检查器核对原文、两端位置、时长与笔记。清理预检还因导入书的默认私密状态被保护条件误拒；确认两端状态后修正该条件，再执行一次移除并独立复核。合成测试覆盖回执丢失后的待核对与不重发。

记录：[首次停止](validation-assets/2026-11-22/cb-offline-reconnect-owner.json)、[只读预演](validation-assets/2026-11-22/cb-offline-reconnect-diagnosis-final.json)、[两尺寸接续](validation-assets/2026-11-22/cb-offline-reconnect-owner-resume.json)、[清理](validation-assets/2026-11-22/cb-offline-reconnect-cleanup.json)和[独立回读](validation-assets/2026-11-22/cb-offline-reconnect-final-readback.json)；[合成往返](validation-assets/2026-11-22/cb-offline-reconnect-mock-resume.json)与[回执丢失](validation-assets/2026-11-22/cb-offline-reconnect-mock-resume-noack.json)。

## 休眠期间的网络变化

休眠时先保存精确原文位置；之后即使收到断网通知，也不会用暂停中的位置采集器覆盖这个检查点。休眠期间收到联网通知不会立刻读取云端或弹窗，而是在唤醒、原文位置准备就绪后进行比较。离线重试仍保留重连选择，账号在休眠期间变更时不会用新账号处理旧位置；未确认的旧发送也不会自动重发。

2026-11-22 在官方 KOReader 模拟器的 600×800 和 KO2 尺寸，用真实账号中的普通 TXT 书籍验证：离线翻页后休眠、休眠中断网和联网、唤醒后选择云端位置，以及全新离线进程重开。检查点保持精确位置，休眠中没有新增请求；独立核对前后云端位置、书架、正文目录及阅读计数，账号数据和授权写入均为零。记录：[普通尺寸](validation-assets/2026-11-22/offline-wake-owner-600.json)、[KO2 尺寸](validation-assets/2026-11-22/offline-wake-owner-ko2.json)。

导入书的本机位置选择还在封闭合成服务上验证了休眠中重连和唤醒后离线重试：选择前零写入，选择本机后由模拟服务独立读回。两种屏幕均通过：[休眠重连 600×800](validation-assets/2026-11-22/cb-offline-wake-mock-600.json)、[休眠重连 KO2](validation-assets/2026-11-22/cb-offline-wake-mock-ko2.json)、[离线重试 600×800](validation-assets/2026-11-22/cb-offline-wake-retry-mock-600.json)、[离线重试 KO2](validation-assets/2026-11-22/cb-offline-wake-retry-mock-ko2.json)。重试计时在模拟中加速；本轮未对真实账号执行导入书休眠后的进度写入，也未验收实体设备、真实 Wi-Fi 切换或断电。

后续增加重复休眠保护：同一次休眠中的重复通知不会再次从已暂停的采集器保存位置，也不会丢弃原先的唤醒恢复意图。真实账号的普通 TXT 在 KO2 模拟尺寸完成重复休眠、断网、联网、选择云端和离线重开；原文位置及云端观察状态保持，账号数据和授权写入均为零。导入书的同一场景以合成服务及模拟写入验证。记录：[真实账号只读](validation-assets/2026-11-22/offline-repeat-suspend-owner-ko2.json)、[导入书合成测试](validation-assets/2026-11-22/offline-repeat-suspend-cb-mock-ko2.json)。

## 普通书重连后的本机位置预演

2026-11-22 使用真实账号的一章普通 XHTML，分别在 600×800 和 KO2 模拟尺寸离线翻页、保存、重连并选择本机位置。原生同步流程生成的首个请求在传输前被禁止发送；守卫核对了同书同章、精确原文偏移、摘要、签名及限定字段。宿主在前后独立核对网页阅读位置、原文、目录和书架投影均未变化，两次验收均为零账号数据和授权写入。原文及凭据只经过内存管道和临时内存文件系统，临时配置已清理；没有真实账号截图。

同一普通书流程在两尺寸使用合成服务完成选择本机后的两次模拟请求、独立位置读回及全新离线进程重开。工具禁止对真实普通书开启写入，真实同步及写后恢复仍待后续独立验证，不能把预演视为云端同步成功；实体设备、多设备并发及实际网络变化也未验收。

首次普通尺寸预演在界面结束后的书架回读被只读工具自身的请求范围拒绝，结果按未验证保留，没有数据或授权写入；修正该只读请求的阶段名并加强发送前守卫后，两尺寸重新验证通过。记录：[首次未验证](validation-assets/2026-11-22/ordinary-reconnect-owner-first-unverified.json)、[普通尺寸预演](validation-assets/2026-11-22/ordinary-reconnect-owner-preview-600.json)、[KO2 预演](validation-assets/2026-11-22/ordinary-reconnect-owner-preview-ko2.json)、[普通尺寸合成](validation-assets/2026-11-22/ordinary-reconnect-mock-600.json)、[KO2 合成](validation-assets/2026-11-22/ordinary-reconnect-mock-ko2.json)。

### 可保留原摘要的普通书候选

新增只读筛选，优先寻找已有摘要可由普通书位置请求原样表达的候选；筛选本身不授予写入权限，也不替代正文、目录及两端状态核对。真实账号的前 67 本数字编号书中有两本符合初步条件；选中的一本另行只读核对了完整来源、原始摘要、两端位置和三项时长计数。600×800 与 KO2 尺寸的实际原生阅读器均完成离线翻页、重连选择和发送前拦截，前后来源、目录、书架和云端位置一致，没有账号数据或授权修改。首轮因模拟器启动环境缺失必要配置而未完成，补齐配置后两尺寸重新通过。见[普通尺寸](validation-assets/2026-11-22/ordinary-restorable-preview-600.json)及 [KO2 尺寸](validation-assets/2026-11-22/ordinary-restorable-preview-ko2.json)。

此结果仅证明可恢复摘要的候选及禁止发送预演，尚未完成真实重连写入、原摘要恢复或实体 Kindle 验收；正式试验仍需独立的一次性发送记录、逐步回读和中断保护。

新的独立记录已实现三次发送的顺序状态：进入、位置上传、恢复各先记录可能发送，再记录明确回执和独立核对；状态不可跳步，旧回执不可复用，结束后的记录也不能重新领取。原始位置、完整摘要及范围摘要只保存在独立钥匙串条目；合成测试覆盖中断、记录损坏、存储回读失败和不匹配范围。另有独立请求检查器，按阶段核对目标、原始摘要、零时长、签名及时间，拒绝重新签名后被篡改的请求。协调器要求每步先检查、领取、确认回执，再等待外部回读；异常后同一执行器停止。其他试验的共享待处理检查已识别此记录；完成的封存记录不会阻塞。真实来源核对尚未接入，恢复传输目前只连接模拟服务。

原生进程与宿主之间的私有消息协调器已在合成消息中覆盖两次请求、逐步回读、无回执、错误顺序及进程结果不完整；任何异常都会停止当前协调器，不会放行恢复步骤。两尺寸的实际 KOReader 进程现已连接协调器和仅用于测试的模拟服务：先在拦截发送的原生预演中绑定本页百分比，再按一次性记录执行两次模拟请求并逐步独立回读，最后通过单次零时长请求恢复原坐标、百分比及完整摘要。上下文缺少会话计数时，首个请求需通过新鲜时间和签名检查，之后的请求绑定同一计数。KO2 尺寸模拟第二次请求回执缺失时，记录停在待核对且没有重发。验证未访问真实账号，见[普通尺寸](validation-assets/2026-11-22/ordinary-reconnect-rpc-600.json)、[KO2 尺寸](validation-assets/2026-11-22/ordinary-reconnect-rpc-ko2.json)与[无回执](validation-assets/2026-11-22/ordinary-reconnect-rpc-noack.json)。真实来源核对及真实账号执行器尚未接入，不能将模拟结果当作真实写入或实体设备验收。

真实账号的禁止发送预演中，书号、章节、原文摘要、目标位置及签名的独立检查通过，但原生进程取得的阅读会话标识与宿主之前独立读取的值不同，因此预演停止，保留为未验证；没有账号数据或授权写入。服务端还以数字零表示缺失的会话计数，现已支持在该情况下检查并绑定新鲜计数。后续需将原生进程实际读取的上下文交给宿主独立校验，不能简单放宽会话检查。见[脱敏记录](validation-assets/2026-11-22/ordinary-reconnect-rpc-owner-unverified.json)。

随后将原生进程实际收到的阅读上下文通过私有内存管道交给宿主，由独立解析器验证书籍、原位置和会话字段，再绑定本次请求；不将上下文写入报告。真实账号的两尺寸禁止发送预演均通过，原文、目录、两端进度与三项计数保持；两端书架的 `lectureSynckey` 随时间变化，其余完整字段及可观察的书架核心状态保持。该游标单独验证为有界、未倒退，不被误报为完整响应不变。临时环境已清理，没有账号数据或授权写入；真实发送与恢复仍未执行。见[普通尺寸](validation-assets/2026-11-22/ordinary-reconnect-rpc-owner-context-600.json)及 [KO2 尺寸](validation-assets/2026-11-22/ordinary-reconnect-rpc-owner-context-ko2.json)。

宿主的独立检查器现会重新核对同一账号、正文与目录、两端完整位置和摘要、三项时长及除该游标外的书架字段；检查前后还验证保存的会话未变化。若检查耗时导致签名过期，协调器不会领取发送。新的检查器已在真实账号 KO2 尺寸禁止发送预演中完成原始状态核对，见[记录](validation-assets/2026-11-22/ordinary-reconnect-rpc-owner-observe-ko2.json)。真实重连及恢复仍未验收。

已将独立检查器与一次性执行流程连接，模拟服务完成“禁止发送预演→原生重连→逐步回读→单次恢复→再次回读”；恢复请求缺少明确回执时也保留待核状态且不重发，见[模拟记录](validation-assets/2026-11-22/ordinary-reconnect-rpc-restore-noack.json)。真实账号模式仍先准备独立钥匙串记录，并在实际派发前重做来源、会话和进度核对；当前尚未执行真实发送。

真实账号的一次性范围已完成准备，来源和会话指纹、目标及原始摘要已核对并写入独立钥匙串记录；准备阶段没有账号数据或授权修改，见[记录](validation-assets/2026-11-22/ordinary-reconnect-owner-prepared.json)。另准备了仅针对封存记录的全新进程只读复核，未封存或结果不明确时不会借此重发。

真实原生重连的第一次请求收到明确成功回执后，独立回读发现章节、目标坐标和摘要已更新，但百分比仍为原值，与本次预期不一致；流程立即停止，没有派发第二次请求或自动恢复。两端只读核对一致，正文、目录和三项时长未变；书架完整字段出现变化，原因尚未确认。原试验保留未验证状态，见[记录](validation-assets/2026-11-22/ordinary-reconnect-owner-partial.json)。原坐标及摘要仍在独立记录中，另在准备针对这一已观察状态的单次恢复，不重跑原试验。

恢复流程使用独立的一次性记录：确认两端均处于已观察状态后，只允许一次零时长原位置恢复，并重新核对两端、原摘要、时长、正文和书架核心状态；完整书架字段如有变化单独报告。KO2 模拟器重现了“首次请求保留原百分比”，单次恢复和回执缺失后禁止重发均通过，见[恢复模拟](validation-assets/2026-11-22/ordinary-partial-recovery-mock.json)和[无回执模拟](validation-assets/2026-11-22/ordinary-partial-recovery-mock-noack.json)。真实恢复前原生授权返回 401，尚未发送恢复请求；续期须以独立记录关联原账号、设备及旧测试，确认新授权后才能继续。

原生授权随后在两次确认过期后续期一次，并核对同账号与设备；两端再次确认测试页后，单次恢复收到明确回执。原坐标、百分比和摘要在恢复时及全新进程中各独立回读两次，三项时长、正文、目录及书架核心状态一致；完整书架部分字段与恢复前不同，原因和服务端历史仍未核实。原重连试验继续标记为未验证，独立恢复记录已封存，不可重发。见[续期](validation-assets/2026-11-22/ordinary-partial-recovery-renewal.json)、[恢复准备](validation-assets/2026-11-22/ordinary-partial-recovery-owner-prepared.json)、[恢复](validation-assets/2026-11-22/ordinary-partial-recovery-owner-restored.json)和[全新进程复核](validation-assets/2026-11-22/ordinary-partial-recovery-owner-independent.json)。

针对这次观察，后续执行器现在分别核对进入请求后的“目标坐标、目标摘要、原百分比”和位置请求后的完整目标，不再将两个阶段混为一谈。书架核对先绑定完整初始快照，之后仅允许目标书的最近阅读时间、列表位置和与当前阶段精确一致的进度发生变化，并要求同步游标不倒退；其他书籍相对顺序、全部其他字段、标记和分组仍需一致。合成服务已模拟上述百分比及最近阅读变化并完成原生往返，见[普通尺寸](validation-assets/2026-11-22/ordinary-reconnect-observed-enter-mock-600.json)、[KO2 尺寸](validation-assets/2026-11-22/ordinary-reconnect-observed-enter-mock-ko2.json)和[回执缺失](validation-assets/2026-11-22/ordinary-reconnect-observed-enter-noack.json)；这尚不代表新的真实账号试验通过。

为后续验证准备了独立的测试、恢复和授权关联存储范围；它们与已封存的记录分开，新的待处理测试也会阻止其他试验。KO2 模拟已覆盖[正常往返](validation-assets/2026-11-22/ordinary-retry-mock-success.json)、[进入回执不明确后的单次恢复](validation-assets/2026-11-22/ordinary-retry-mock-enter-noack-recovery.json)、[位置回执不明确后的单次恢复](validation-assets/2026-11-22/ordinary-retry-mock-partial-recovery.json)、[恢复回执缺失](validation-assets/2026-11-22/ordinary-retry-mock-recovery-noack.json)及[恢复回执缺失后的只读确认](validation-assets/2026-11-22/ordinary-retry-mock-readback-resolution.json)。新的真实账号范围先完成了[零写入准备](validation-assets/2026-11-22/ordinary-retry-owner-prepared.json)。


2026-11-22 的第二次真实重连试验在第一条进入请求获得明确回执后，独立网页读取遭 HTTP 拒绝，随即停止，未发送后续位置请求；原记录未保存状态码，不能判断具体原因。随后以独立范围只读核对两次已知测试位置，单次恢复原位置，并在全新进程再次独立核对两次：原章节、位置、百分比、摘要、时长计数、原文、目录和书架核心状态一致。完整书架的部分字段与恢复前不同，不能断言排序或其他服务端历史恢复。该次完整重连试验仍为未验证，恢复成功不等于完整同步通过，原试验及恢复范围均不能重发。记录：[中断](validation-assets/2026-11-22/ordinary-retry-owner-apply.json)、[恢复准备](validation-assets/2026-11-22/ordinary-retry-recovery-prepared.json)、[单次恢复](validation-assets/2026-11-22/ordinary-retry-recovery-apply.json)、[新进程复核](validation-assets/2026-11-22/ordinary-retry-recovery-independent.json)。后续验证工具会保留去敏请求阶段及状态码，以便区分服务器拒绝原因；不会自动重发。

2026-11-22 的后续只读预演重新核对实际账号、普通 XHTML 来源和两端位置；网页 100 次及原生 8 次读取均返回 HTTP 200，签名请求预演和独立回读通过，账号数据及授权写入为零。它只能说明本轮读取成功，无法还原上次未记录的拒绝状态码，也不能代替真实重连写入。见[去敏记录](validation-assets/2026-11-22/ordinary-followup-readonly-dry.json)。

另在两种模拟屏幕使用合成账号复现进入请求确认后、下一次读取返回 HTTP 503：原生流程只领取并确认第一次修改，独立读取失败即停，没有派发位置请求；独立恢复范围随后只发送一次恢复，并检查原始位置和摘要。该 503 是人为模拟，不能解释此前真实拒绝；见[普通尺寸](validation-assets/2026-11-22/ordinary-enter-read-failure-small.json)和 [KO2 尺寸](validation-assets/2026-11-22/ordinary-enter-read-failure-ko2.json)。

后续准备了第三个独立范围：原先两次试验与恢复记录不重置，新范围、恢复、续期和只读核对分别使用独立记录，并与其他试验互斥。合成服务在两尺寸验证[正常往返](validation-assets/2026-11-22/ordinary-third-mock-success-small.json)及 [KO2 尺寸](validation-assets/2026-11-22/ordinary-third-mock-success-ko2.json)；KO2 尺寸另验证[进入后读取失败](validation-assets/2026-11-22/ordinary-third-mock-read-failure-ko2.json)、[进入回执缺失](validation-assets/2026-11-22/ordinary-third-mock-enter-noack-ko2.json)、[位置回执缺失](validation-assets/2026-11-22/ordinary-third-mock-position-noack-ko2.json)、[恢复回执缺失后的只读确认](validation-assets/2026-11-22/ordinary-third-mock-restore-noack-ko2.json)和[恢复回执缺失不重发](validation-assets/2026-11-22/ordinary-third-mock-recovery-noack-ko2.json)。这些均为合成账号，不代表真实同步成功。新的真实账号范围先完成[零写入准备](validation-assets/2026-11-22/ordinary-third-owner-prepared.json)，已核对原位置、原文、目录、两端计数及书架。

2026-11-22 的第三次真实普通 XHTML 重连试验中，两次原生进度请求均获得明确回执；第二次后独立网页状态核对未通过，流程停止，未派发原计划恢复。停止后的独立只读检查观察到目标坐标和目标摘要，但百分比仍为原值，目标百分比与原值确实不同；该后续观察不能证明停止瞬间只有百分比一项不符。独立恢复范围随后单次恢复原位置，两端两轮回读以及全新进程两轮复核均确认原位置、摘要、计数、来源和书架核心状态；完整书架的部分字段与恢复前不同，排序及服务端历史不保证恢复。真实完整重连试验仍未验证，第三次记录与恢复均已封存，不重发。见[试验](validation-assets/2026-11-22/ordinary-third-owner-apply.json)、[停止后状态](validation-assets/2026-11-22/ordinary-third-state-diagnosis.json)、[恢复准备](validation-assets/2026-11-22/ordinary-third-recovery-prepared.json)、[恢复](validation-assets/2026-11-22/ordinary-third-recovery-apply.json)和[独立复核](validation-assets/2026-11-22/ordinary-third-recovery-independent.json)。

针对这一后续观察，试验核对在位置请求后可接受服务端返回目标百分比或保留原百分比；两端仍必须一致，章节、精确坐标、摘要、目录、原文、时长和书架均按对应实际状态核对，其他百分比与两端不一致均拒绝。位置读取会记录百分比采用的分支，原位置恢复仍要求精确匹配。两尺寸合成服务保留原百分比的完整往返通过：[普通尺寸](validation-assets/2026-11-22/ordinary-preserved-percent-small.json)、[KO2](validation-assets/2026-11-22/ordinary-preserved-percent-ko2.json)；这不代表真实账号已验证该分支或服务端百分比已同步。

新增第四个独立范围，原有记录保持封存。两尺寸合成服务覆盖原百分比保留的[普通尺寸](validation-assets/2026-11-22/ordinary-fourth-mock-preserved-small.json)和 [KO2](validation-assets/2026-11-22/ordinary-fourth-mock-preserved-ko2.json)完整往返，以及 KO2 尺寸目标百分比、读取失败和各阶段回执缺失后的恢复或不重发；这些合成结果不代表真实账号通过。首次真实准备时原生授权返回 401，独立读取再次确认过期，未修改书籍；同设备续期一次后重新[零写入准备](validation-assets/2026-11-22/ordinary-fourth-owner-prepared-v2.json)通过，见[首次准备](validation-assets/2026-11-22/ordinary-fourth-owner-prepared.json)、[过期核对](validation-assets/2026-11-22/ordinary-fourth-native-expiry-check.json)和[续期](validation-assets/2026-11-22/ordinary-fourth-native-renewal.json)。

2026-11-22 的第四次真实普通 XHTML 重连验证在 KO2 模拟尺寸完成：通过插件书架进入原生阅读器，模拟断网翻页并保存位置，重连后选择本机进度。两次原生进度请求各获得明确回执，每次之后均由网页及墨水屏通道独立核对；位置请求后的两轮回读均确认精确章节、坐标和摘要为目标，百分比保留原值，不能据此宣称目标百分比已同步。随后一次零时长请求恢复原位置并获得明确回执；全新进程再独立读回两轮，原位置、摘要、时长计数、原文、目录和书架核心状态一致。共三次账号数据请求、零授权请求；完整书架其他字段、最近阅读排序及服务端历史不保证恢复。范围已封存，不可重发。见[实际往返](validation-assets/2026-11-22/ordinary-fourth-owner-apply.json)及[新进程复核](validation-assets/2026-11-22/ordinary-fourth-owner-independent.json)。本次仅覆盖一本书的一章、软件模拟网络切换；实体 KO2、多设备并发、其他正文及百分比行为仍需验证。

## 普通 TXT 重连后的真实同步与恢复

随后使用真实账号的一章普通 TXT，在 KO2 模拟尺寸从插件进入原生阅读器，模拟断网并翻页，保存本机位置后重连，选择「保留 KOReader 进度」。实际原生同步发送一次零时长位置请求；明确回执和插件回读后，宿主独立核对网页／墨水屏位置及摘要、原文和目录、原生阅读时长计数与网页书架投影，才放行一次恢复原位置的请求。恢复后再次独立核对；另在全新宿主进程连续两次只读核对，原章节、偏移、百分比、摘要和上述观察状态均一致。两次数据请求均获得明确回执，验收期间没有网页位置写入或授权请求。

两次请求使用独立持久意图，分别在发送前领取；每步完成独立核对才允许下一步，结果不明确不会自动重发。该意图现为 `retired`，两次额度均已消费，不能再次运行；原文位置和恢复信息只存放在本机钥匙串及临时内存环境中。两种模拟尺寸的合成服务完成相同往返；回执丢失场景只发生一次模拟发送，意图保留待核对。实体设备、自然网络切换、多设备并发、其他书籍和普通 XHTML 的真实重连写入仍待验收；服务端最近阅读时间或其他未返回的历史不保证恢复。

首次准备遇到原生授权 HTTP 401，独立只读请求确认后续期一次，同账号与书架回读通过；本次续期有一次授权请求、零书籍数据写入。续期后准备阶段零写入通过，首次重复预演在来源准备之后、发送前停止，原因未能确定；意图仍为 `prepared`、写入领取为零。随后两次零写入预演均通过，才执行上述受限往返。完整记录：[过期](validation-assets/2026-11-22/native-reconnect-owner-expired.json)、[续期](validation-assets/2026-11-22/native-reconnect-owner-renewal.json)、[准备](validation-assets/2026-11-22/native-reconnect-owner-prepared.json)、[停止的预演](validation-assets/2026-11-22/native-reconnect-owner-dry-stopped.json)、[预演一](validation-assets/2026-11-22/native-reconnect-owner-dry-1.json)、[预演二](validation-assets/2026-11-22/native-reconnect-owner-dry-2.json)、[实际往返](validation-assets/2026-11-22/native-reconnect-owner-apply.json)、[新进程复核](validation-assets/2026-11-22/native-reconnect-owner-independent.json)；合成验证：[普通尺寸](validation-assets/2026-11-22/native-reconnect-mock-600.json)、[KO2](validation-assets/2026-11-22/native-reconnect-mock-ko2.json)、[回执丢失](validation-assets/2026-11-22/native-reconnect-mock-noack.json)。
