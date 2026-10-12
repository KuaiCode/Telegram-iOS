import UIKit
import AppBundle
import Display
import ContextUI
import SGStrings

extension ChatControllerImpl {
    func messageFilterMenuItem() -> ContextMenuItem? {
        let historyNode = self.chatDisplayNode.historyNode
        guard historyNode.canToggleMessageFilter else { return nil }
        let key = historyNode.showsFilteredMessages ? "MessageFilter.RestoreFiltering" : "MessageFilter.ShowFiltered"
        return .action(ContextMenuActionItem(text: key.i18n(self.presentationData.strings.baseLanguageCode), icon: { theme in
            generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Search"), color: theme.contextMenu.primaryColor)
        }, action: { [weak historyNode] _, completion in
            completion(.default)
            historyNode?.toggleFilteredMessages()
        }))
    }
}
