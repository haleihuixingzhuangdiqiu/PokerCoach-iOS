// Adapted from the user-owned XiangqiCoach single-entry capture UI. See docs/SOURCES.md.
import ReplayKit
import SwiftUI

struct BroadcastPickerView: UIViewRepresentable {
    static var extensionBundleIdentifier: String { (Bundle.main.bundleIdentifier ?? "org.research.pokercoach") + ".broadcast" }
    static let preferredSize = CGSize(width: 220, height: 64)

    var title: String = "开始"
    var isEnabled: Bool = true
    var onTap: () -> Void = {}

    func makeUIView(context: Context) -> PreparedBroadcastPickerView {
        // ReplayKit 用初始尺寸建立按钮；不能从 .zero 开始，否则内部按钮可能出现无穷坐标。
        let picker = PreparedBroadcastPickerView(frame: CGRect(origin: .zero, size: Self.preferredSize))
        picker.update(title: title, isEnabled: isEnabled, onTap: onTap)
        return picker
    }

    func updateUIView(_ uiView: PreparedBroadcastPickerView, context: Context) {
        uiView.update(title: title, isEnabled: isEnabled, onTap: onTap)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PreparedBroadcastPickerView, context: Context) -> CGSize? {
        CGSize(width: Self.dimension(proposal.width, fallback: Self.preferredSize.width),
               height: Self.dimension(proposal.height, fallback: Self.preferredSize.height))
    }

    private static func dimension(_ proposed: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let proposed, proposed.isFinite, proposed > 0 else { return fallback }
        return proposed
    }
}

/// 将系统按钮本身扩展并样式化，保留 ReplayKit 的 targets 和系统录屏确认流程。
/// 触屏准备监听 touchDown；辅助功能激活显式先准备，再发送系统按钮已注册的公开 UIControl 事件。
final class PreparedBroadcastPickerView: RPSystemBroadcastPickerView {
    static let preparationActionIdentifier = UIAction.Identifier("poker.prepare-broadcast")
    static let startColor = UIColor(red: 0.10, green: 0.32, blue: 0.25, alpha: 1)

    private(set) weak var broadcastButton: UIButton?
    private var buttonTitle = "开始"
    private var enabled = true
    private var onTap: () -> Void = {}
    private var nativeActivationEvent: UIControl.Event = .touchUpInside

    override init(frame: CGRect) {
        super.init(frame: frame)
        preferredExtension = BroadcastPickerView.extensionBundleIdentifier
        showsMicrophoneButton = false
        isAccessibilityElement = true
        accessibilityIdentifier = "capture.start"
        accessibilityHint = "打开系统录屏确认页"
        bindButtonIfNeeded()
        update(title: buttonTitle, isEnabled: enabled, onTap: onTap)
    }

    required init?(coder: NSCoder) {
        // 此视图仅由 UIViewRepresentable 以真实非零尺寸创建，不从 storyboard 恢复。
        return nil
    }

    override var intrinsicContentSize: CGSize { BroadcastPickerView.preferredSize }

    func update(title: String, isEnabled: Bool, onTap: @escaping () -> Void) {
        buttonTitle = title
        enabled = isEnabled
        self.onTap = onTap
        isUserInteractionEnabled = isEnabled
        accessibilityLabel = title
        accessibilityTraits = isEnabled ? [.button] : [.button, .notEnabled]
        bindButtonIfNeeded()
        styleButton()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bindButtonIfNeeded()
        // 必须在系统布局之后设置，避免 ReplayKit 把按钮恢复成初始尺寸；全矩形都是原生按钮命中区。
        broadcastButton?.frame = bounds
    }

    override func accessibilityActivate() -> Bool {
        guard enabled, isUserInteractionEnabled, let button = broadcastButton, button.isEnabled else { return false }
        prepare()
        guard enabled, button.isEnabled else { return false }
        // 这是 VoiceOver 用户的主动激活，只打开系统确认页；不调用私有 selector，也不代按“开始直播”。
        button.sendActions(for: nativeActivationEvent)
        return true
    }

    private func prepare() {
        guard enabled, isUserInteractionEnabled, broadcastButton?.isEnabled == true else { return }
        onTap()
    }

    private func bindButtonIfNeeded() {
        guard let button = Self.findButton(in: self), button !== broadcastButton else { return }
        broadcastButton?.removeAction(identifiedBy: Self.preparationActionIdentifier, for: .touchDown)
        broadcastButton = button
        // 当前 ReplayKit 使用 touchUpInside；若系统改为语义主动作，辅助功能同样转交既有注册事件。
        nativeActivationEvent = button.allControlEvents.contains(.touchUpInside) ? .touchUpInside : .primaryActionTriggered
        button.addAction(UIAction(identifier: Self.preparationActionIdentifier) { [weak self] _ in
            self?.prepare()
        }, for: .touchDown)
        // 暴露一个辅助功能按钮，避免 VoiceOver 直接激活内部按钮而遗漏应用准备。
        button.isAccessibilityElement = false
        button.accessibilityElementsHidden = true
        // The container exposes the single accessible start control. Some iOS
        // accessibility snapshots still include this hidden UIKit child.
        button.accessibilityIdentifier = nil
        styleButton()
    }

    private func styleButton() {
        guard let button = broadcastButton else { return }
        var configuration = UIButton.Configuration.filled()
        configuration.title = buttonTitle
        configuration.image = nil
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = enabled ? Self.startColor : UIColor(white: 0.78, alpha: 1)
        configuration.background.cornerRadius = 0
        configuration.cornerStyle = .fixed
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = UIFont.systemFont(ofSize: 23, weight: .semibold)
            return result
        }
        button.configuration = configuration
        button.isEnabled = enabled
        button.layer.cornerRadius = 0
        button.accessibilityLabel = buttonTitle
        for state: UIControl.State in [.normal, .highlighted, .selected, .disabled] {
            button.setImage(nil, for: state)
        }
    }

    private static func findButton(in view: UIView) -> UIButton? {
        for child in view.subviews {
            if let button = child as? UIButton { return button }
            if let button = findButton(in: child) { return button }
        }
        return nil
    }
}
