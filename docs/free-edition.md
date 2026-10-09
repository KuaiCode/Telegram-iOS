# Airygram 免费版维护说明

本分支在保留 Swiftgram 上游实现的基础上，免费开放应用内已有的 Swiftgram Pro 本地功能，并停止本应用的 Swiftgram 购买、恢复购买和会员校验流程。Telegram Premium、Telegram 服务端限制及其他 Swiftgram 服务的真实权限保持各自原有含义。

## 实现约定

- 唯一免费版策略是 `Swiftgram/SGSimpleSettings/Sources/SGFeaturePolicy.swift` 中固定为 `true` 的 `SGFeaturePolicy.isFreeEdition`，不增加用户设置、远端开关或新的构建参数。
- 本地功能入口使用免费版策略或原会员资格决定是否可用。原始 `SGStatus`、`shared.status`、`ephemeralStatus` 及其持久化结构保留，不写入虚构会员状态、不清空历史会员数据。
- 免费策略只移除会员门槛。用户开关、系统版本要求、通知的会话例外、消息方向和关键词检查等原有条件继续生效。
- 保留上游付费模块、公共调用接口和非免费版分支，避免删除模块后持续处理上游引用变化。免费版在统一入口提前结束付费流程，仍须正确结束回调和加载状态。
- 只阻断 Swiftgram 付费链，包括 StoreKit 商品查询、购买、恢复、收据与会员状态查询。其他 `SGAPI` 服务、翻译、社区、语言资源、Telegram Premium 和服务器权限不在此次变更范围内。

覆盖的本地路径包括 Pro 设置与会话备份入口、App Badge、三套输入工具栏、消息关键词过滤，以及通知扩展中的屏蔽通知和静音策略。会话备份的 Keychain 保护与存取逻辑保持不变；本分支此前已移除旧图标选择，本次不恢复该入口。

普通购买入口不显示；旧购买入口或相关深链应进入可用设置或安全返回，不显示购买/恢复中的状态。调试页的购买恢复与会员重置入口同样不向免费版展示。启动、切换账号和后台通知路径都不能依赖一次性的 UI 状态来维持免费访问。

## 与上游同步

直接上游是 `Swiftgram/Telegram-iOS`。`origin` 是 `KuaiCode/Telegram-iOS`；不要照搬继承文档中的 `TelegramMessenger/Telegram-iOS` 示例覆盖现有 `upstream`。

- `codex/swiftgram-upstream` 保持纯上游历史，不放品牌和免费版修改。
- `codex/swiftgram-free` 保留 Airygram 品牌及免费版提交，采用合并方式接收上游，不改写已共享分支的提交历史。
- 免费权益、购买入口和回归维护分别使用独立中文逻辑提交。避免将格式化、无关重命名、构建系统维修混入；不再维护另一套正则替换脚本或 `.patch` 副本。

以下命令从仓库根目录运行。先确认 `git status --short` 没有输出；有本地修改时先处理自己的修改，不丢弃他人的工作。逐条执行，任一步失败或出现冲突就先解决并复核，不能继续套用后续命令：

```sh
git status --short
git switch codex/swiftgram-upstream
git fetch upstream
git merge --ff-only upstream/master
git switch codex/swiftgram-free
git merge codex/swiftgram-upstream
python scripts/check_free_edition.py
python Tests/Branding/check_airygram_branding.py
git diff --check
```

两个 Python 检查只使用标准库。免费版检查用于发现策略入口、已知会员门槛或付费流程保护发生漂移；品牌检查保护已完成的 Airygram 修改。检查失败时应先判断是上游接口变化还是回归，不应为了通过检查直接修改预期。

每次同步还需阅读上游新增的会员判断、付费页面、深链和通知扩展变化，确认是否有新的本地功能绕过统一策略。无合并冲突、静态检查通过，都不能证明所有新路径已覆盖。之后完成下节的 macOS 与通知实测，再发布构建。

## macOS 与真机验收

构建环境按仓库 `versions.json` 准备；本说明编写时为 macOS 26、Xcode 26.2、Bazel 8.4.2。沿用 `README.md` 的配置和工程生成流程，不因免费版另建一套构建系统。应分别验证主应用与通知扩展成功编译。

已有 XCUITest 位于 `Telegram/Tests/Sources/`，目标为 `iOSAppUITestSuite`，目前只包含启动和注册测试。注册用例 `testSignUp` 结尾有无条件的 `XCTFail("UI DUMP:…")`，不是可通过的验收用例；下方命令仅运行 `testLaunch`。测试使用 `--ui-test` 隔离数据并连接 Telegram 测试服务器，每次启动会清空该测试数据目录；启动测试不能代替免费版功能验收。`Tests/AllTests` 也只包含通话测试。

生成工程后，可用以下命令列出模拟器，并将 `<SIMULATOR_UDID>` 替换成现有模拟器的 UDID 后运行测试：

```sh
xcrun simctl list devices available
xcodebuild test \
  -project Telegram/Swiftgram.xcodeproj \
  -scheme iOSAppUITestSuite \
  -only-testing:iOSAppUITestSuite/UITests/testLaunch \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>'
```

实际工程名来自 `build-system/Make/ProjectGeneration.py` 和 `Telegram/BUILD`；`docs/ui-testing.md` 中旧的 `Telegram/Telegram.xcodeproj` 示例不应直接套用。新增 UI 回归可以沿用现有测试目标；跨重启、旧缓存和真实推送场景需要独立测试步骤，不能由每次清空数据的启动测试推断。

发布前至少验证以下场景，并记录设备、系统版本、账号状态和结果：

| 场景 | 验收要求 |
| --- | --- |
| 无会员、无购买记录的首次启动 | 本地 Pro 功能可进入并实际工作，没有付款要求或会员加载等待。 |
| 离线、重启、多账号切换 | 已有本地功能持续可用，不依赖购买缓存或某一个账号的会员状态。 |
| 旧免费/会员缓存及异步状态变化 | 原状态保留，免费访问不被状态刷新重新锁定。 |
| 设置、App Badge、输入工具栏、备份 | 逐项操作；用户关闭功能时仍关闭，系统版本限制与 Keychain 行为保持正常。 |
| 消息关键词过滤 | 按原设置过滤符合条件的传入消息；不误过滤发出消息、空关键词或原本无需过滤的消息。 |
| 购买、恢复、调试与深链入口 | 无购买请求、无恢复等待；旧入口安全结束或转到可用设置。必要时观察 StoreKit 与网络调用。 |
| 通知扩展 | 在真机前后台、应用退出及多账号情况下，分别验证屏蔽通知、静音和会话例外；未受规则影响的通知可正常到达。 |
| 非本地权限与其他服务 | Telegram Premium 仍显示真实账号状态；其他 SGAPI 服务继续按原逻辑运行，不被免费策略一起关闭。 |

## 本轮验证边界与现有问题

2026-10-09 的执行环境为 Windows，PowerShell 7.6.5、Python 3.12.7；当前 PATH 中没有 `swift`、`swiftc`、`bazel`、`xcodebuild`、`xcrun`。本机可以运行上述 Python 静态检查，不能据此声称 Swift 已编译、XCUITest 已通过、StoreKit 或 iOS 通知扩展已完成运行验收。检查命令的实际通过情况应以本轮执行输出为准。

现有 `.github/workflows/build.yml` 仅支持手动触发，仍使用 `macos-13`，与当前版本文件中的 macOS/Xcode 要求不一致；它收集 `Telegram.ipa`，而当前 `Make.py` 使用 `Swiftgram.ipa`。这些是原有构建流程问题，本次免费化只记录、不顺带修复，也不把该 CI 当作已可用的验证保证。

根 `AGENTS.md` 指向的 `swiftgram-scripts/AGENTS.md` 在本轮检出中不存在，且 `swiftgram-scripts` 被 `.gitignore` 忽略。免费版检查和维护说明应保留在已跟踪的 `scripts/`、`Tests/`、`docs/` 中，使新检出和后续同步能够取得同一份约定。
