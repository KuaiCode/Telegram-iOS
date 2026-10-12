import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import TextSelectionNode
import SGSimpleSettings
import SGStrings

@available(iOS 13.0, *)
public func sgMessageFilterKeywordSelectionController(text: String, presentationData: PresentationData) -> ViewController {
    let controller = ActionSheetController(presentationData: presentationData)
    let item = MessageFilterKeywordSelectionItem(text: text, presentationData: presentationData, controller: controller)
    controller.setItemGroups([ActionSheetItemGroup(items: [item])])
    return controller
}

@available(iOS 13.0, *)
private final class MessageFilterKeywordSelectionItem: ActionSheetItem {
    let text: String
    let presentationData: PresentationData
    weak var controller: ActionSheetController?

    init(text: String, presentationData: PresentationData, controller: ActionSheetController) {
        self.text = text
        self.presentationData = presentationData
        self.controller = controller
    }

    func node(theme: ActionSheetControllerTheme) -> ActionSheetItemNode {
        return MessageFilterKeywordSelectionNode(theme: theme, text: text, presentationData: presentationData, controller: controller)
    }

    func updateNode(_ node: ActionSheetItemNode) {
    }
}

@available(iOS 13.0, *)
private final class MessageFilterKeywordSelectionNode: ActionSheetItemNode {
    private let sheetTheme: ActionSheetControllerTheme
    private let presentationData: PresentationData
    private let text: String
    private weak var controller: ActionSheetController?
    private let titleLabel = UILabel()
    private let helpLabel = UILabel()
    private let countLabel = UILabel()
    private let statusLabel = UILabel()
    private let closeButton = HighlightTrackingButton()
    private let submitButton = HighlightTrackingButton()
    private let groupButton = HighlightTrackingButton()
    private let textBackground = ASDisplayNode()
    private let textNode = ImmediateTextNode()
    private var selectionNode: TextSelectionNode?
    private var keywordButtons: [HighlightTrackingButton] = []
    private var keywords: [String] = []
    private var targetGroupName: String?
    private var isPresentingGroupPicker = false
    private var isSubmitting = false
    private var wordRanges: [NSRange] = []
    private var rotorIndex: Int?
    private var textLayoutWidth: CGFloat?
    private var textLayoutSize = CGSize()

    private var lang: String { presentationData.strings.baseLanguageCode }

    init(theme: ActionSheetControllerTheme, text: String, presentationData: PresentationData, controller: ActionSheetController?) {
        self.sheetTheme = theme
        self.presentationData = presentationData
        self.text = text
        self.controller = controller
        self.targetGroupName = SGSimpleSettings.shared.messageFilter.preferredKeywordGroup?.name
        super.init(theme: theme)
        self.hasSeparator = false

        for label in [titleLabel, helpLabel, countLabel, statusLabel] {
            label.numberOfLines = 0
            label.textColor = theme.primaryTextColor
            label.font = Font.regular(theme.baseFontSize)
            self.view.addSubview(label)
        }
        titleLabel.font = Font.semibold(theme.baseFontSize)
        titleLabel.textAlignment = .center
        titleLabel.text = "MessageFilter.Selection.Title".i18n(lang)
        titleLabel.accessibilityTraits = .header
        helpLabel.text = "MessageFilter.Selection.Help".i18n(lang)
        helpLabel.textColor = theme.secondaryTextColor
        statusLabel.textColor = theme.secondaryTextColor
        countLabel.accessibilityTraits = .header

        for button in [closeButton, submitButton, groupButton] {
            button.titleLabel?.font = Font.regular(theme.baseFontSize)
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byWordWrapping
            button.setTitleColor(theme.standardActionTextColor, for: .normal)
            button.setTitleColor(theme.disabledActionTextColor, for: .disabled)
            self.view.addSubview(button)
        }
        closeButton.contentHorizontalAlignment = .left
        closeButton.setTitle("MessageFilter.Selection.Close".i18n(lang), for: .normal)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        submitButton.contentHorizontalAlignment = .right
        submitButton.setTitle("MessageFilter.Selection.Submit".i18n(lang), for: .normal)
        submitButton.addTarget(self, action: #selector(submit), for: .touchUpInside)
        groupButton.contentHorizontalAlignment = .left
        groupButton.addTarget(self, action: #selector(chooseGroup), for: .touchUpInside)

        textBackground.backgroundColor = theme.itemHighlightedBackgroundColor.withAlphaComponent(0.35)
        textBackground.cornerRadius = 10.0
        self.addSubnode(textBackground)
        textNode.maximumNumberOfLines = 0
        textNode.displaysAsynchronously = false
        textNode.attributedText = NSAttributedString(string: text, font: Font.regular(theme.baseFontSize), textColor: theme.primaryTextColor)
        self.addSubnode(textNode)

        let selection = TextSelectionNode(
            theme: TextSelectionTheme(selection: theme.controlAccentColor.withAlphaComponent(0.25), knob: theme.controlAccentColor, isDark: presentationData.theme.overallDarkAppearance),
            strings: presentationData.strings,
            textNodeOrView: .node(textNode),
            updateIsActive: { _ in },
            present: { [weak self] menu, arguments in
                self?.controller?.present(menu, in: .window(.root), with: arguments)
            },
            rootView: { [weak controller] in controller?.view },
            performAction: { _, _ in }
        )
        selection.enableCopy = false
        selection.enableLookup = false
        selection.enableQuote = false
        selection.enableTranslate = false
        selection.enableShare = false
        selection.additionalMenuActions = { [weak self] selectedText in
            guard let self = self else { return [] }
            let title = "MessageFilter.Selection.AddKeyword".i18n(self.lang)
            return [ContextMenuAction(content: .text(title: title, accessibilityLabel: title), action: { [weak self] in
                self?.addKeyword(selectedText.string)
            })]
        }
        self.selectionNode = selection
        controller?.dismissed = { [weak self] _ in self?.selectionNode?.cancelSelection() }
        self.insertSubnode(selection.highlightAreaNode, belowSubnode: textNode)
        self.addSubnode(selection)
        configureAccessibility()
        updatePending()
    }

    private func configureAccessibility() {
        textNode.isAccessibilityElement = true
        textNode.accessibilityLabel = text
        textNode.accessibilityTraits = .staticText
        textNode.accessibilityHint = "MessageFilter.Selection.AccessibilityHelp".i18n(lang)
        text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: .byWords) { _, range, _, _ in
            self.wordRanges.append(NSRange(range, in: self.text))
        }
        let words = wordRanges
        text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: .byComposedCharacterSequences) { substring, range, _, _ in
            let range = NSRange(range, in: self.text)
            if let substring = substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !words.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                self.wordRanges.append(range)
            }
        }
        wordRanges.sort { $0.location < $1.location }
        textNode.view.accessibilityCustomRotors = [UIAccessibilityCustomRotor(name: "MessageFilter.Selection.Words".i18n(lang), itemSearch: { [weak self] predicate in
            guard let self = self else { return nil }
            let forward = predicate.searchDirection == .next
            let index = (self.rotorIndex ?? (forward ? -1 : self.wordRanges.count)) + (forward ? 1 : -1)
            guard self.wordRanges.indices.contains(index) else { return nil }
            self.rotorIndex = index
            self.selectionNode?.setSelection(range: self.wordRanges[index], displayMenu: false)
            let value = (self.text as NSString).substring(with: self.wordRanges[index])
            self.textNode.accessibilityValue = value
            UIAccessibility.post(notification: .announcement, argument: value)
            return UIAccessibilityCustomRotorItemResult(targetElement: self.textNode.view, targetRange: nil)
        })]
        textNode.view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "MessageFilter.Selection.AddKeyword".i18n(lang), target: self, selector: #selector(addSelection)),
            UIAccessibilityCustomAction(name: presentationData.strings.TextSelection_SelectAll, target: self, selector: #selector(selectAllText))
        ]
    }

    @objc private func selectAllText() -> Bool {
        guard !text.isEmpty else { return false }
        selectionNode?.setSelection(range: NSRange(location: 0, length: (text as NSString).length), displayMenu: false)
        textNode.accessibilityValue = text
        return true
    }

    @objc private func addSelection() -> Bool {
        let source = text as NSString
        guard let range = selectionNode?.getSelection(), range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= source.length, range.length <= source.length - range.location else { return false }
        let completeRange = source.rangeOfComposedCharacterSequences(for: range)
        addKeyword(source.substring(with: completeRange))
        return true
    }

    private func addKeyword(_ keyword: String) {
        keywords = SGMessageFilterStore.normalizedKeywords(keywords + [keyword])
        selectionNode?.cancelSelection()
        textNode.accessibilityValue = nil
        statusLabel.text = nil
        updatePending()
        UIAccessibility.post(notification: .announcement, argument: countLabel.text)
    }

    private func updatePending() {
        for button in keywordButtons { button.removeFromSuperview() }
        keywordButtons.removeAll()
        for (index, keyword) in keywords.enumerated() {
            let button = HighlightTrackingButton()
            button.tag = index
            button.titleLabel?.font = Font.regular(sheetTheme.baseFontSize)
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byWordWrapping
            button.contentEdgeInsets = UIEdgeInsets(top: 8.0, left: 12.0, bottom: 8.0, right: 12.0)
            button.setTitle(keyword + "  ×", for: .normal)
            button.setTitleColor(sheetTheme.controlAccentColor, for: .normal)
            button.backgroundColor = sheetTheme.controlAccentColor.withAlphaComponent(0.12)
            button.layer.cornerRadius = 12.0
            button.accessibilityLabel = "MessageFilter.Selection.RemoveKeyword".i18n(lang).replacingOccurrences(of: "{keyword}", with: keyword)
            button.addTarget(self, action: #selector(removeKeyword(_:)), for: .touchUpInside)
            self.view.addSubview(button)
            keywordButtons.append(button)
        }
        countLabel.text = "MessageFilter.Selection.PendingCount".i18n(lang).replacingOccurrences(of: "{count}", with: String(keywords.count))
        submitButton.isEnabled = !keywords.isEmpty && !isSubmitting
        updateGroupTitle()
        self.requestLayout?()
    }

    private func updateGroupTitle() {
        let configuration = SGSimpleSettings.shared.messageFilter.configuration
        let group = configuration.groups.first(where: { $0.name == targetGroupName })
        let isDefaultGroup = targetGroupName == nil && configuration.groups.isEmpty
        let name = group?.name ?? (isDefaultGroup ? "MessageFilter.Selection.DefaultGroup".i18n(lang) : "—")
        let action = (group?.action ?? .dim).localizationKey.i18n(lang)
        let actionLabel = group != nil || isDefaultGroup ? " · " + action : ""
        groupButton.setTitle("MessageFilter.Selection.Group".i18n(lang) + ": " + name + actionLabel + "  ›", for: .normal)
    }

    @objc private func removeKeyword(_ sender: UIButton) {
        guard keywords.indices.contains(sender.tag) else { return }
        keywords.remove(at: sender.tag)
        statusLabel.text = nil
        updatePending()
    }

    @objc private func close() {
        selectionNode?.cancelSelection()
        controller?.dismissAnimated()
    }

    @objc private func chooseGroup() {
        guard !isPresentingGroupPicker, let controller = controller else { return }
        selectionNode?.cancelSelection()
        let groups = SGSimpleSettings.shared.messageFilter.configuration.groups
        guard !groups.isEmpty else {
            targetGroupName = nil
            statusLabel.text = nil
            updateGroupTitle()
            self.requestLayout?()
            return
        }
        isPresentingGroupPicker = true
        let picker = ActionSheetController(presentationData: presentationData)
        let items: [ActionSheetItem] = groups.map { group in
            let action = group.action.localizationKey.i18n(lang)
            return ActionSheetButtonItem(title: group.name + " · " + action, action: { [weak self, weak picker] in
                self?.targetGroupName = group.name
                self?.statusLabel.text = nil
                self?.updateGroupTitle()
                self?.requestLayout?()
                picker?.dismissAnimated()
            })
        }
        picker.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: "MessageFilter.Cancel".i18n(lang), action: { [weak picker] in picker?.dismissAnimated() })
        ])])
        picker.dismissed = { [weak self] _ in self?.isPresentingGroupPicker = false }
        controller.present(picker, in: .window(.root))
    }

    @objc private func submit() {
        guard !isSubmitting, !keywords.isEmpty else { return }
        isSubmitting = true
        submitButton.isEnabled = false
        do {
            let added = try SGSimpleSettings.shared.messageFilter.appendKeywords(keywords, toGroupNamed: targetGroupName, defaultGroupName: "MessageFilter.Selection.DefaultGroup".i18n(lang))
            if added > 0 {
                UIAccessibility.post(notification: .announcement, argument: "MessageFilter.Selection.Saved".i18n(lang).replacingOccurrences(of: "{count}", with: String(added)))
                close()
                return
            }
            statusLabel.text = "MessageFilter.Selection.AllDuplicate".i18n(lang)
        } catch SGMessageFilterKeywordError.targetGroupMissing {
            statusLabel.text = "MessageFilter.Selection.TargetMissing".i18n(lang)
            if !SGSimpleSettings.shared.messageFilter.configuration.groups.isEmpty {
                chooseGroup()
            }
        } catch {
            let key: String
            if let error = error as? SGMessageFilterRuleFileError, error == .fileTooLarge {
                key = "MessageFilter.Error.FileTooLarge"
            } else if let error = error as? SGMessageFilterRuleFileError, error == .unreadableStoredConfiguration {
                key = "MessageFilter.Error.StoredConfiguration"
            } else {
                key = "MessageFilter.Error.FileAccess"
            }
            statusLabel.text = key.i18n(lang)
        }
        isSubmitting = false
        submitButton.isEnabled = true
        updateGroupTitle()
        self.requestLayout?()
        UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
    }

    private func sizeForButton(_ button: UIButton, width: CGFloat) -> CGSize {
        let insets = button.contentEdgeInsets
        let labelSize = button.titleLabel?.sizeThatFits(CGSize(width: max(1.0, width - insets.left - insets.right), height: .greatestFiniteMagnitude)) ?? .zero
        return CGSize(width: min(width, max(44.0, ceil(labelSize.width + insets.left + insets.right))), height: max(44.0, ceil(labelSize.height + insets.top + insets.bottom)))
    }

    override func updateLayout(constrainedSize: CGSize, transition: ContainedViewLayoutTransition) -> CGSize {
        let inset: CGFloat = 16.0
        let width = max(1.0, constrainedSize.width - inset * 2.0)
        let buttonWidth = max(1.0, (width - 16.0) / 2.0)
        let buttonHeight = max(sizeForButton(closeButton, width: buttonWidth).height, sizeForButton(submitButton, width: buttonWidth).height)
        closeButton.frame = CGRect(x: inset, y: 6.0, width: buttonWidth, height: buttonHeight)
        submitButton.frame = CGRect(x: constrainedSize.width - inset - buttonWidth, y: 6.0, width: buttonWidth, height: buttonHeight)
        var y = buttonHeight + 14.0
        for label in [titleLabel, helpLabel] {
            let size = label.sizeThatFits(CGSize(width: width, height: 1000.0))
            label.frame = CGRect(x: inset, y: y, width: width, height: size.height)
            y += size.height + 12.0
        }
        let textWidth = max(1.0, width - 24.0)
        if textLayoutWidth != textWidth {
            textLayoutWidth = textWidth
            let maximumHeight = CGFloat(max(1, (text as NSString).length + 1)) * ceil(Font.regular(sheetTheme.baseFontSize).lineHeight + 1.0)
            textLayoutSize = textNode.updateLayout(CGSize(width: textWidth, height: maximumHeight))
        }
        let textFrame = CGRect(x: inset + 12.0, y: y + 12.0, width: textWidth, height: max(1.0, textLayoutSize.height))
        textBackground.frame = CGRect(x: inset, y: y, width: width, height: textFrame.height + 24.0)
        textNode.frame = textFrame
        selectionNode?.frame = textFrame
        selectionNode?.highlightAreaNode.frame = textFrame
        selectionNode?.updateLayout()
        y = textBackground.frame.maxY + 12.0
        let groupHeight = sizeForButton(groupButton, width: width).height
        groupButton.frame = CGRect(x: inset, y: y, width: width, height: groupHeight)
        y += groupHeight + 12.0
        let countSize = countLabel.sizeThatFits(CGSize(width: width, height: 1000.0))
        countLabel.frame = CGRect(x: inset, y: y, width: width, height: countSize.height)
        y += countSize.height + 10.0
        var x = inset
        var rowHeight: CGFloat = 0.0
        for button in keywordButtons {
            let buttonSize = sizeForButton(button, width: width)
            if x > inset, x + buttonSize.width > constrainedSize.width - inset {
                x = inset
                y += rowHeight + 8.0
                rowHeight = 0.0
            }
            button.frame = CGRect(origin: CGPoint(x: x, y: y), size: buttonSize)
            x += buttonSize.width + 8.0
            rowHeight = max(rowHeight, buttonSize.height)
        }
        y += rowHeight
        if let status = statusLabel.text, !status.isEmpty {
            let size = statusLabel.sizeThatFits(CGSize(width: width, height: 1000.0))
            statusLabel.frame = CGRect(x: inset, y: y + 12.0, width: width, height: size.height)
            y = statusLabel.frame.maxY
        } else {
            statusLabel.frame = .zero
        }
        let size = CGSize(width: constrainedSize.width, height: y + 20.0)
        self.updateInternalLayout(size, constrainedSize: constrainedSize)
        return size
    }
}
