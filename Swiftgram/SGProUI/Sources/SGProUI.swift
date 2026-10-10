import Foundation
import SGItemListUI
import SGStrings
import UndoUI
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData


private enum SGProControllerSection: Int32, SGItemListSection {
    case base
}

private enum SGProDisclosureLink: String {
    case messageFilter
}

private typealias SGProControllerEntry = SGItemListUIEntry<SGProControllerSection, AnyHashable, AnyHashable, AnyHashable, SGProDisclosureLink, AnyHashable>

private func SGProControllerEntries(presentationData: PresentationData) -> [SGProControllerEntry] {
    let lang = presentationData.strings.baseLanguageCode
    return [.disclosure(id: 1, section: .base, link: .messageFilter, text: "MessageFilter.Title".i18n(lang))]
}

public func okUndoController(_ text: String, _ presentationData: PresentationData) -> UndoOverlayController {
    return UndoOverlayController(presentationData: presentationData, content: .succeed(text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false })
}

public func sgProController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?

    let arguments = SGItemListArguments<AnyHashable, AnyHashable, AnyHashable, SGProDisclosureLink, AnyHashable>(context: context, openDisclosureLink: { _ in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        pushControllerImpl?(sgMessageFilterController(presentationData: presentationData))
    })
    
    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        
        let entries = SGProControllerEntries(presentationData: presentationData)
        
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Settings.Advance.Title".i18n(presentationData.strings.baseLanguageCode)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: /*focusOnItemTag*/ nil, initialScrollToItem: nil /* scrollToItem*/ )
        
        return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    // Workaround
    let _ = pushControllerImpl
    
    return controller
}


