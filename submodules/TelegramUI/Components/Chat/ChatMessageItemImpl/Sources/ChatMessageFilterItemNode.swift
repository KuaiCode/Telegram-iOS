import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import ChatMessageItem
import ChatMessageItemCommon
import ChatMessageItemView
import SGStrings

final class ChatMessageFilterItemNode: ChatMessageItemView {
    private let button = HighlightTrackingButtonNode()
    private let label = TextNode()

    required init(rotated: Bool) {
        super.init(rotated: rotated)
        self.label.isUserInteractionEnabled = false
        self.button.cornerRadius = 12.0
        self.button.isAccessibilityElement = true
        self.button.accessibilityTraits = .button
        self.button.addTarget(self, action: #selector(self.expand), forControlEvents: .touchUpInside)
        self.addSubnode(self.button)
        self.button.addSubnode(self.label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func expand() {
        guard let item = self.item else { return }
        item.controllerInteraction.setMessageFilterRevealed?(item.message.id, true, item.content.firstMessageAttributes.messageFilterGeneration)
    }

    override func asyncLayout() -> (ChatMessageItem, ListViewItemLayoutParams, ChatMessageMerge, ChatMessageMerge, ChatMessageHeaderSpec) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation, ListViewItemApply, Bool) -> Void) {
        let makeLabel = TextNode.asyncLayout(self.label)
        return { [weak self] item, params, _, _, header in
            let groupName = item.content.firstMessageAttributes.messageFilterMatch?.groupName ?? ""
            let title = "MessageFilter.Collapsed".i18n(item.presentationData.strings.baseLanguageCode, args: groupName)
            let theme = item.presentationData.theme.theme
            let width = max(44.0, params.width - params.leftInset - params.rightInset - 64.0)
            let (labelLayout, applyLabel) = makeLabel(TextNodeLayoutArguments(attributedString: NSAttributedString(string: title, font: Font.regular(item.presentationData.fontSize.baseDisplaySize), textColor: theme.list.itemAccentColor), backgroundColor: nil, maximumNumberOfLines: 2, truncationType: .end, constrainedSize: CGSize(width: width - 24.0, height: .greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: .zero))
            let height = max(44.0, labelLayout.size.height + 20.0)
            let constants = ChatMessageItemLayoutConstants.compact
            let headerHeight: CGFloat = header.hasTopic ? constants.timestampDateAndTopicHeaderHeight : (header.hasDate ? constants.timestampHeaderHeight : 0.0)
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets(top: 6.0 + headerHeight, left: 0.0, bottom: 6.0, right: 0.0))
            return (layout, { _, _, _ in
                guard let self else { return }
                self.item = item
                let _ = applyLabel()
                self.button.frame = CGRect(x: params.leftInset + 48.0, y: 0.0, width: width, height: height)
                self.button.backgroundColor = theme.list.itemBlocksBackgroundColor
                self.button.accessibilityLabel = title
                self.label.frame = CGRect(x: floor((width - labelLayout.size.width) / 2.0), y: floor((height - labelLayout.size.height) / 2.0), width: labelLayout.size.width, height: labelLayout.size.height)
            })
        }
    }

    override func contentFrame() -> CGRect {
        return self.button.frame
    }
}
