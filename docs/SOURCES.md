# 资料与来源

查阅与复核日期：2026-09-15 至 2026-09-16。以下开源项目用于架构/算法对照，没有把它们未经验证地当成完整多人 AI 引擎装入本工程。

| 来源 | 本工程借鉴及限制 |
| --- | --- |
| 用户本地 `XiangqiCoach` 项目／任务「查找并安装 iOS 象棋项目」 | 复用 `FrameSender.swift`、`FrameReceiver.swift`、`FrameProtocol.swift` 的本机录屏传输、背压和时效处理。协议魔数与端口改为本项目独立值，长边上限改为 1440、采样上限 15 Hz、发送过期 200 ms。另按最新首页流程移植 `BroadcastPickerView.swift` 的原生按钮样式及准备事件；借鉴一次录屏只自动启动一次 PiP、稳定显示层身份与音频初始化顺序。没有复制棋引擎、NNUE 权重或象棋图片。 |
| [PokerKit](https://github.com/uoftcprg/pokerkit) 与 [统计文档](https://pokerkit.readthedocs.io/en/stable/analysis.html) | 对照范围、多人 equity、统计分析接口。当前为独立 Swift 实现，无 Python 运行时依赖。 |
| [PokerHandEvaluator](https://github.com/HenryRLee/PokerHandEvaluator) | 对照高性能牌型评估的分层设计；未复制哈希表或代码，当前使用直接点数/花色统计。 |
| [OpenSpiel](https://github.com/google-deepmind/open_spiel) | 后续策略训练/博弈评估框架参考；当前没有将研究环境当作可直接接 WPK 的产品。 |
| [RLCard](https://github.com/datamllab/rlcard) | 研究环境与训练接口参考，实际 WPK 的下注额和事件历史不能直接等同于默认离散动作。 |
| [postflop-solver](https://github.com/b-inary/postflop-solver) | 范围、下注树、实时求解接口参考；主要是双人翻牌后，不能作为多人整局引擎直接替换。 |
| [DecisionHoldem](https://github.com/AI-Decision/DecisionHoldem) | 离线基础策略与实时搜索架构参考；双人无限注，不能声称已具备本任务多人能力。 |
| [Pluribus 论文](https://doi.org/10.1126/science.aay2400) | 六人研究成果说明多人目标可行；本工程未复现其策略或取得同等强度证据。 |
| [Deep CFR 原论文](https://proceedings.mlr.press/v97/brown19b.html) | 训练框架研究参考；本项目当前没有训练、下载或内置其多人策略权重。 |
| [ReBeL 原论文](https://proceedings.neurips.cc/paper/2020/hash/c61f571dbd2fb949d3fe5ae1608dd48b-Abstract.html)、[官方仓库](https://github.com/facebookresearch/rebel) | 公共信念状态与搜索的研究参考；两人零和保证不能直接套用于八人第三盲。官方公开实现范围不等于现成多人扑克模型。 |
| [Apple ReplayKit](https://developer.apple.com/documentation/replaykit) | 系统录屏/扩展接口。不同 SDK 可用性与弃用标记需要按实际部署版本核对，本工程另做了本机 iOS SDK 编译。 |
| [Apple PiP ContentSource](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class) | 通过 sample-buffer layer 呈现小型提示内容；具体可用性与后台生命周期需真机验证。 |
| [WPK 官网](https://www.wpk.com/) | 目标平台资料。没有找到可据以实现本项目的公开 Bot SDK；当前从用户提供的可见录屏适配。 |

## 用户视频与模板

高清源为用户提供的 `11111.mp4`（720×1564、约 120.23 秒）。压缩源为同内容微信版本（220×480）。原视频与完整抽帧保留在用户本地和任务 scratch 中，未打包进算法库。

点数字形模板保存裁剪后的二值特征，JSON 的 `source` 字段记录对应视频帧或后续截图。A、5、6 的部分样本来自后续截图；A 和 5 有另留截图验证，6 目前没有独立 holdout，不能声称其泛化通过。其他视频帧验证仍局限同一主题和原录像。

`wpk-clear-wager-templates.json` 另保存小块 RGBA 裁剪，包含空下注区域、筹码数字 0 和下注数字 1，用于补充明确视觉证据；它们不是完整牌桌截图。模板匹配相似度不是校准后的识别正确率，回放通过也不等于能覆盖未知主题或手机运行条件。

当前源代码没有加入第三方多人策略权重。研究/发布之前须按实际引入的组件分别核对许可，不能把“可以公开下载”当成“整个产品可按任意许可证发布”。

## 画中画黑屏修复参考

- [Apple：立即显示的逐样本标记](https://developer.apple.com/documentation/coremedia/kcmsampleattachmentkey_displayimmediately)：不规则状态更新使用 sample attachment 请求立即显示。
- [Apple：视频样本入队](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/enqueue(_:))：iOS 17 起使用 `sampleBufferRenderer`，不混用两套入队接口。
- [Apple：IOSurface 像素缓冲区属性](https://developer.apple.com/documentation/corevideo/kcvpixelbufferiosurfacepropertieskey)，结合本机 SDK 头文件与真机前后对照验证。

## 屏幕读取产品复核

2026-09-16 继续核查以下作者仓库。这里借鉴的是拆分识别、状态恢复、决策和验收的工程方法，没有复制源码或装入第三方模型。

| 项目 | 可用思路与限制 |
| --- | --- |
| [PyPokerBot](https://github.com/gbencke/PyPokerBot) | 截图采集、区域检测、OCR、HUD 分层；作者明确其策略为简单决策树，不能作为强度证明。桌面 Win32/Python 架构也不能直接当作 iOS 插件。 |
| [Poker](https://github.com/dickreuter/Poker) | 图形化桌面区域适配、OpenCV/神经网络识别、蒙特卡洛权益；可借鉴把主题校准与策略分开。GPL-3.0 项目，本轮未复制代码，也未独立复现其盈利表现。 |
| [pokertv](https://github.com/BrunoPradoBR/pokertv) | 分区图像分类、OCR 去抖、状态机生成牌谱。适合对照“单帧字段 → 连续事件”的设计；需要自行训练并放入模型，不能据 README 认定已覆盖目标桌面。 |
| [PokerScreenBot](https://github.com/Vlad-Boyar/PokerScreenBot) | 提供屏幕管线的基础结构，但公开仓库明确排除模型及 solver 数据；不是完整可运行强策略的权重来源。 |

本次由录像证实的缺陷是本工程遗漏了本人座位的第三盲标签区域，并漏掉了该标签的蓝紫色渐变。已补实际区域和颜色候选，同时仍要求读到明确的 `Straddle` 字样；不能用“看见下注 1”替代桌规证据。策略项目的权重、许可与适用人数另见 [本轮研究报告](STRATEGY-RESEARCH-2026-09-16.md)，规则恢复见 [恢复研究](RECOVERY-RESEARCH.md)。
