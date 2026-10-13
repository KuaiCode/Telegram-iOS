import Foundation
import SGItemListUI
import SGStrings
import SGSimpleSettings
import UndoUI
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData


private enum SGProControllerSection: Int32, SGItemListSection {
    case base
    case restrictions
}

private enum SGProBoolSetting: Hashable {
    case ignoreAppleTerms
    case allowGroupCopyingAndScreenshots
}

private enum SGProDisclosureLink: String {
    case messageFilter
}

private typealias SGProControllerEntry = SGItemListUIEntry<SGProControllerSection, SGProBoolSetting, AnyHashable, AnyHashable, SGProDisclosureLink, AnyHashable>

private func SGProControllerEntries(presentationData: PresentationData) -> [SGProControllerEntry] {
    let lang = presentationData.strings.baseLanguageCode
    return [
        .disclosure(id: 1, section: .base, link: .messageFilter, text: "MessageFilter.Title".i18n(lang)),
        .toggle(id: 2, section: .restrictions, settingName: .ignoreAppleTerms, value: SGSimpleSettings.shared.ignoreAppleTerms, text: "Settings.Advance.IgnoreAppleTerms".i18n(lang), enabled: true),
        .notice(id: 3, section: .restrictions, text: "Settings.Advance.IgnoreAppleTerms.Notice".i18n(lang)),
        .toggle(id: 4, section: .restrictions, settingName: .allowGroupCopyingAndScreenshots, value: SGSimpleSettings.shared.allowGroupCopyingAndScreenshots, text: "Settings.Advance.AllowGroupCopyingAndScreenshots".i18n(lang), enabled: true),
        .notice(id: 5, section: .restrictions, text: "Settings.Advance.AllowGroupCopyingAndScreenshots.Notice".i18n(lang)),
        .notice(id: 6, section: .restrictions, text: "Settings.Advance.RestrictionsRestart".i18n(lang))
    ]
}

public func okUndoController(_ text: String, _ presentationData: PresentationData) -> UndoOverlayController {
    return UndoOverlayController(presentationData: presentationData, content: .succeed(text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false })
}

public func sgProController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    let settingsUpdated = ValuePromise(false, ignoreRepeated: false)

    let arguments = SGItemListArguments<SGProBoolSetting, AnyHashable, AnyHashable, SGProDisclosureLink, AnyHashable>(context: context, setBoolValue: { setting, value in
        switch setting {
        case .ignoreAppleTerms:
            SGSimpleSettings.shared.ignoreAppleTerms = value
        case .allowGroupCopyingAndScreenshots:
            SGSimpleSettings.shared.allowGroupCopyingAndScreenshots = value
        }
        settingsUpdated.set(value)
    }, openDisclosureLink: { _ in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        pushControllerImpl?(sgMessageFilterController(presentationData: presentationData))
    })
    
    let signal = combineLatest(context.sharedContext.presentationData, settingsUpdated.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        
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


