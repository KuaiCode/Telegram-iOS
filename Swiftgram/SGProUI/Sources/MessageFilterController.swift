import Foundation
import UIKit
import UIKitRuntimeUtils
import SwiftUI
import SGSwiftUI
import SGStrings
import SGSimpleSettings
import LegacyUI
import LegacyMediaPickerUI
import Display
import Postbox
import TelegramPresentationData

@available(iOS 13.0, *)
struct MessageFilterKeywordInputFieldModifier: ViewModifier {
    @Binding var newKeyword: String
    let onAdd: () -> Void
    
    func body(content: Content) -> some View {
        if #available(iOS 15.0, *) {
            content
                .submitLabel(.return)
                .submitScope(false) // TODO(swiftgram): Keyboard still closing
                .interactiveDismissDisabled()
                .onSubmit {
                    onAdd()
                }
        } else {
            content
        }
    }
}


@available(iOS 13.0, *)
struct MessageFilterKeywordInputView: View {
    @Environment(\.lang) var lang: String
    @Binding var newKeyword: String
    let onAdd: () -> Void
    var isRegularExpression = false

    private var isEmpty: Bool {
        return isRegularExpression ? newKeyword.isEmpty : SGMessageFilterRule.normalized(newKeyword).isEmpty
    }

    var body: some View {
        HStack {
            TextField((isRegularExpression ? "MessageFilter.Regex.InputPlaceholder" : "MessageFilter.InputPlaceholder").i18n(lang), text: $newKeyword)
                .disableAutocorrection(true)
                .autocapitalization(.none)
                .keyboardType(.default)
                .modifier(MessageFilterKeywordInputFieldModifier(newKeyword: $newKeyword, onAdd: onAdd))
                
            
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(isEmpty ? .secondary : .accentColor)
                    .imageScale(.large)
            }
            .accessibility(label: Text((isRegularExpression ? "MessageFilter.Regex.Add" : "MessageFilter.AddKeyword").i18n(lang)))
            .disabled(isEmpty)
            .buttonStyle(PlainButtonStyle())
        }
    }
}

@available(iOS 13.0, *)
struct MessageFilterView: View {
    weak var wrapperController: LegacyController?
    let theme: PresentationTheme
    @Environment(\.lang) var lang: String

    @State private var configuration: SGMessageFilterConfiguration
    @State private var newGroupName = ""
    @State private var selectedGroupId: Int?
    @State private var isBusy = false
    @State private var errorMessage: String?

    init(wrapperController: LegacyController?, theme: PresentationTheme) {
        self.wrapperController = wrapperController
        self.theme = theme
        _configuration = State(initialValue: SGSimpleSettings.shared.messageFilter.configuration)
    }

    var bodyContent: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "nosign.app.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    Text("MessageFilter.Title".i18n(lang))
                        .font(.title)
                        .bold()
                    Text("MessageFilter.Groups.Description".i18n(lang))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowInsets(EdgeInsets())
            }

            Section(footer: Text("MessageFilter.MatchingMode.Help".i18n(lang))) {
                Picker("MessageFilter.MatchingMode".i18n(lang), selection: Binding(
                    get: { configuration.matchingMode },
                    set: { mode in
                        var updated = configuration
                        updated.matchingMode = mode
                        _ = save(updated)
                    }
                )) {
                    Text("MessageFilter.MatchingMode.FirstMatch".i18n(lang)).tag(SGMessageFilterMatchingMode.firstMatch)
                    Text("MessageFilter.MatchingMode.Strongest".i18n(lang)).tag(SGMessageFilterMatchingMode.strongest)
                }
            }

            Section {
                Button("MessageFilter.Import".i18n(lang), action: importRules)
                Button("MessageFilter.ExportAll".i18n(lang)) {
                    chooseExportFormat(configuration)
                }
            }

            Section(header: Text("MessageFilter.Groups".i18n(lang)), footer: Text("MessageFilter.Groups.OrderHelp".i18n(lang))) {
                // Positional IDs keep navigation stable while a group's name is edited.
                ForEach(configuration.groups, id: \.id) { group in
                    NavigationLink(destination: MessageFilterGroupView(group: group, wrapperController: wrapperController, onError: showError, onExport: { selected in
                        chooseExportFormat(SGMessageFilterConfiguration(matchingMode: configuration.matchingMode, groups: [selected]))
                    }), tag: group.id, selection: $selectedGroupId) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name)
                            Text(groupSummary(group))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onMove { source, destination in
                    var updated = configuration
                    updated.groups.move(fromOffsets: source, toOffset: destination)
                    _ = save(updated)
                }
                .onDelete { offsets in
                    showOptions(title: "MessageFilter.DeleteGroup.Help".i18n(lang), options: [
                        ("MessageFilter.DeleteGroup".i18n(lang), true, {
                            var updated = configuration
                            updated.groups.remove(atOffsets: offsets)
                            _ = save(updated)
                        })
                    ])
                }
                HStack {
                    TextField("MessageFilter.GroupName".i18n(lang), text: $newGroupName, onCommit: addGroup)
                        .disableAutocorrection(true)
                    Button(action: addGroup) {
                        Image(systemName: "plus.circle.fill").imageScale(.large)
                    }
                    .accessibility(label: Text("MessageFilter.AddGroup".i18n(lang)))
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .disabled(isBusy || SGSimpleSettings.shared.messageFilter.loadError != nil)
        .navigationBarBackButtonHidden(true)
        .navigationBarItems(leading: NavigationBarBackButton(action: {
            wrapperController?.dismiss()
        }).padding(.leading, -8), trailing: EditButton())
    }

    var body: some View {
        NavigationView {
            bodyContent
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onReceive(NotificationCenter.default.publisher(for: SGMessageFilterStore.didChange).receive(on: DispatchQueue.main)) { _ in
            configuration = SGSimpleSettings.shared.messageFilter.configuration
        }
        .onAppear {
            // The inner navigation stack owns edge swipes while a group is open.
            wrapperController?.view.disablesInteractiveTransitionGestureRecognizerNow = { selectedGroupId != nil }
            if let error = SGSimpleSettings.shared.messageFilter.loadError {
                showError(error)
            }
        }
        .onDisappear {
            wrapperController?.view.disablesInteractiveTransitionGestureRecognizerNow = nil
        }
        .alert(isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Alert(title: Text("MessageFilter.Error".i18n(lang)), message: Text(errorMessage ?? ""), dismissButton: .default(Text("MessageFilter.OK".i18n(lang))))
        }
    }

    private func groupSummary(_ group: SGMessageFilterGroup) -> String {
        let action = group.action.localizationKey.i18n(lang)
        return "MessageFilter.GroupSummary".i18n(lang)
            .replacingOccurrences(of: "{action}", with: action)
            .replacingOccurrences(of: "{count}", with: String(group.keywords.count))
    }

    private func save(_ updated: SGMessageFilterConfiguration) -> Bool {
        do {
            try SGSimpleSettings.shared.messageFilter.update(updated)
            configuration = SGSimpleSettings.shared.messageFilter.configuration
            return true
        } catch {
            showError(error)
            return false
        }
    }

    private func addGroup() {
        guard !newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var updated = configuration
        updated.groups.append(SGMessageFilterGroup(id: updated.groups.count + 1, name: newGroupName))
        if save(updated) {
            newGroupName = ""
        }
    }

    private func showOptions(title: String, options: [(String, Bool, () -> Void)]) {
        guard !isBusy, let wrapperController = wrapperController else { return }
        isBusy = true
        let sheet = ActionSheetController(theme: ActionSheetControllerTheme(presentationTheme: theme, fontSize: .regular))
        var selectedAction: (() -> Void)?
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: title)]
        items.append(contentsOf: options.map { title, destructive, action in
            ActionSheetButtonItem(title: title, color: destructive ? .destructive : .accent, action: { [weak sheet] in
                guard selectedAction == nil else { return }
                selectedAction = action
                sheet?.dismissAnimated()
            })
        })
        sheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: "MessageFilter.Cancel".i18n(lang), color: .accent, font: .bold, action: { [weak sheet] in
                sheet?.dismissAnimated()
            })])
        ])
        sheet.dismissed = { _ in
            // Present the next controller after the sheet has left the presentation stack.
            DispatchQueue.main.async {
                isBusy = false
                selectedAction?()
                selectedAction = nil
            }
        }
        wrapperController.present(sheet, in: .window(.root))
    }

    private func importRules() {
        guard !isBusy, let wrapperController = wrapperController else { return }
        isBusy = true
        var receivedResult = false
        let picker = legacyICloudFilePicker(theme: theme, mode: .import, documentTypes: ["public.json", "public.plain-text"], dismissed: {
            DispatchQueue.main.async {
                if !receivedResult { isBusy = false }
            }
        }, completion: { urls in
            guard !receivedResult else { return }
            receivedResult = true
            guard let url = urls.first else {
                isBusy = false
                return
            }
            guard let format = SGMessageFilterFileFormat(rawValue: url.pathExtension.lowercased()) else {
                afterFilePickerDismissal {
                    isBusy = false
                    showError(SGMessageFilterRuleFileError.unsupportedFormat)
                }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let result = Result {
                    try SGMessageFilterRuleFile.decode(data: SGMessageFilterRuleFile.read(url: url), format: format, groupName: url.deletingPathExtension().lastPathComponent)
                }
                DispatchQueue.main.async {
                    afterFilePickerDismissal {
                        isBusy = false
                        switch result {
                        case let .success(imported):
                            previewImport(imported, format: format)
                        case let .failure(error):
                            showError(error)
                        }
                    }
                }
            }
        })
        wrapperController.present(picker, in: .window(.root))
    }

    private func afterFilePickerDismissal(_ action: @escaping () -> Void) {
        guard let presenter = wrapperController?.view.window?.rootViewController else {
            isBusy = false
            return
        }
        if let picker = presenter.presentedViewController as? UIDocumentPickerViewController {
            if picker.isBeingDismissed, let transition = picker.transitionCoordinator {
                let scheduled = transition.animate(alongsideTransition: nil, completion: { _ in
                    DispatchQueue.main.async(execute: action)
                })
                if !scheduled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { afterFilePickerDismissal(action) }
                }
            } else {
                picker.dismiss(animated: true, completion: action)
            }
        } else {
            action()
        }
    }

    private func previewImport(_ imported: SGMessageFilterConfiguration, format: SGMessageFilterFileFormat) {
        let keywordCount = imported.groups.reduce(0) { $0 + $1.keywords.count }
        let title = "MessageFilter.Import.Preview".i18n(lang)
            .replacingOccurrences(of: "{groups}", with: String(imported.groups.count))
            .replacingOccurrences(of: "{rules}", with: String(keywordCount))
        showOptions(title: title, options: [
            ("MessageFilter.Import.Merge".i18n(lang), false, {
                _ = save(configuration.merging(imported))
            }),
            ((keywordCount == 0 ? "MessageFilter.Import.ReplaceEmpty" : "MessageFilter.Import.Replace").i18n(lang), true, {
                var replacement = imported
                if format == .txt { replacement.matchingMode = configuration.matchingMode }
                _ = save(replacement)
            })
        ])
    }

    private func chooseExportFormat(_ selected: SGMessageFilterConfiguration) {
        showOptions(title: "MessageFilter.Export.Format".i18n(lang), options: [
            ("MessageFilter.Export.JSON".i18n(lang), false, { exportRules(selected, format: .json) }),
            ("MessageFilter.Export.TXT".i18n(lang), false, { exportRules(selected, format: .txt) })
        ])
    }

    private func exportRules(_ selected: SGMessageFilterConfiguration, format: SGMessageFilterFileFormat) {
        guard !isBusy, let wrapperController = wrapperController else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let file = TempBox.shared.tempFile(fileName: "Airygram-Message-Filter.\(format.rawValue)")
            do {
                let data = try SGMessageFilterRuleFile.encode(configuration: selected, format: format)
                try data.write(to: URL(fileURLWithPath: file.path), options: .atomic)
                DispatchQueue.main.async {
                    var disposed = false
                    let finish = {
                        guard !disposed else { return }
                        disposed = true
                        TempBox.shared.dispose(file)
                        isBusy = false
                    }
                    let picker = legacyICloudFilePicker(theme: theme, mode: .export, url: URL(fileURLWithPath: file.path), documentTypes: [], dismissed: finish, completion: { _ in finish() })
                    wrapperController.present(picker, in: .window(.root))
                }
            } catch {
                TempBox.shared.dispose(file)
                DispatchQueue.main.async {
                    isBusy = false
                    showError(error)
                }
            }
        }
    }

    private func showError(_ error: Error) {
        errorMessage = messageFilterErrorText(error, language: lang)
    }
}

private func messageFilterErrorText(_ error: Error, language: String) -> String {
    let key: String
    if let error = error as? SGMessageFilterRuleFileError {
        switch error {
        case .fileTooLarge: key = "MessageFilter.Error.FileTooLarge"
        case .unsupportedFormat: key = "MessageFilter.Error.UnsupportedFormat"
        case .emptyGroupName: key = "MessageFilter.Error.EmptyGroupName"
        case .duplicateGroupName: key = "MessageFilter.Error.DuplicateGroupName"
        case .emptyKeyword: key = "MessageFilter.Error.EmptyKeyword"
        case .multilineKeyword: key = "MessageFilter.Error.MultilineKeyword"
        case let .invalidRegularExpression(rule):
            return "MessageFilter.Error.InvalidRegex".i18n(language).replacingOccurrences(of: "{rule}", with: rule)
        case .unreadableStoredConfiguration: key = "MessageFilter.Error.StoredConfiguration"
        case .invalidFile, .invalidGroupID, .duplicateGroupID: key = "MessageFilter.Error.InvalidFile"
        }
    } else if error as? SGMessageFilterKeywordError == .targetGroupMissing {
        key = "MessageFilter.Selection.TargetMissing"
    } else {
        return "MessageFilter.Error.FileAccess".i18n(language) + "\n" + error.localizedDescription
    }
    return key.i18n(language)
}

@available(iOS 13.0, *)
private final class MessageFilterGroupEditor: ObservableObject {
    @Published private(set) var group: SGMessageFilterGroup
    @Published private(set) var name: String
    @Published private(set) var error: Error?
    private var isComposing = false
    private var pendingRename: DispatchWorkItem?

    init(group: SGMessageFilterGroup) {
        self.group = group
        self.name = group.name
    }

    deinit {
        pendingRename?.cancel()
    }

    func nameChanged(_ name: String, isComposing: Bool) {
        guard self.name != name || self.isComposing != isComposing else { return }
        self.name = name
        self.isComposing = isComposing
        pendingRename?.cancel()
        pendingRename = nil
        error = nil
        guard !isComposing else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.saveName()
        }
        pendingRename = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @discardableResult
    func saveName() -> Bool {
        pendingRename?.cancel()
        pendingRename = nil
        guard !isComposing else { return false }
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            error = SGMessageFilterRuleFileError.emptyGroupName
            return false
        }
        let oldName = group.name
        guard update({ $0.name = newName }) else { return false }
        SGSimpleSettings.shared.messageFilter.renameLastUsedGroup(from: oldName, to: group.name)
        return true
    }

    func finishEditing(_ text: String) {
        nameChanged(text, isComposing: false)
        if saveName() {
            name = group.name
        }
    }

    @discardableResult
    func update(_ change: (inout SGMessageFilterGroup) -> Void) -> Bool {
        let store = SGSimpleSettings.shared.messageFilter
        var latest = store.configuration
        guard let index = latest.groups.firstIndex(where: { $0.name == group.name }) else {
            error = SGMessageFilterKeywordError.targetGroupMissing
            return false
        }
        change(&latest.groups[index])
        do {
            try store.update(latest)
            group = store.configuration.groups[index]
            error = nil
            return true
        } catch {
            self.error = error
            return false
        }
    }
}

@available(iOS 13.0, *)
private struct MessageFilterGroupNameField: UIViewRepresentable {
    let editor: MessageFilterGroupEditor
    let placeholder: String

    final class Coordinator: NSObject, UITextFieldDelegate {
        let editor: MessageFilterGroupEditor

        init(editor: MessageFilterGroupEditor) {
            self.editor = editor
        }

        @objc func textChanged(_ field: UITextField) {
            editor.nameChanged(field.text ?? "", isComposing: field.markedTextRange != nil)
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            textChanged(textField)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            guard textField.markedTextRange == nil else { return }
            editor.finishEditing(textField.text ?? "")
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(editor: editor)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = UIFont.preferredFont(forTextStyle: .body)
        field.textColor = .label
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        field.placeholder = placeholder
        field.accessibilityLabel = placeholder
        if field.markedTextRange == nil, field.text != editor.name {
            field.text = editor.name
        }
    }
}

private extension String {
    var messageFilterRuleIdentity: Data { SGMessageFilterRule.identity(self) }
}

@available(iOS 13.0, *)
private struct MessageFilterGroupView: View {
    @Environment(\.lang) var lang: String
    @StateObject private var editor: MessageFilterGroupEditor
    @State private var newKeyword = ""
    @State private var isRegularExpression = false
    weak var wrapperController: LegacyController?
    let onError: (Error) -> Void
    let onExport: (SGMessageFilterGroup) -> Void

    init(group: SGMessageFilterGroup, wrapperController: LegacyController?, onError: @escaping (Error) -> Void, onExport: @escaping (SGMessageFilterGroup) -> Void) {
        _editor = StateObject(wrappedValue: MessageFilterGroupEditor(group: group))
        self.wrapperController = wrapperController
        self.onError = onError
        self.onExport = onExport
    }

    var body: some View {
        List {
            Section(header: Text("MessageFilter.GroupName".i18n(lang))) {
                MessageFilterGroupNameField(editor: editor, placeholder: "MessageFilter.GroupName".i18n(lang))
                if let error = editor.error {
                    Text(messageFilterErrorText(error, language: lang))
                        .font(.footnote)
                        .foregroundColor(.red)
                }
                Picker("MessageFilter.Action".i18n(lang), selection: Binding(get: { editor.group.action }, set: { action in
                    editor.update { $0.action = action }
                })) {
                    ForEach(SGMessageFilterAction.allCases, id: \.self) { action in
                        Text(action.localizationKey.i18n(lang)).tag(action)
                    }
                }
                Button("MessageFilter.ExportGroup".i18n(lang)) {
                    wrapperController?.view.endEditing(true)
                    if editor.saveName() {
                        onExport(editor.group)
                    }
                }
            }
            Section(header: Text("MessageFilter.Keywords.Title".i18n(lang)), footer: Text("MessageFilter.Regex.Help".i18n(lang))) {
                Toggle("MessageFilter.Regex.Use".i18n(lang), isOn: $isRegularExpression)
                MessageFilterKeywordInputView(newKeyword: $newKeyword, onAdd: addKeyword, isRegularExpression: isRegularExpression)
                ForEach(editor.group.keywords.reversed(), id: \.messageFilterRuleIdentity) { keyword in
                    VStack(alignment: .leading, spacing: 4.0) {
                        Text(keyword)
                        if let error = SGMessageFilterRule.validationError(for: keyword) {
                            Text(messageFilterErrorText(error, language: lang))
                                .font(.footnote)
                                .foregroundColor(.red)
                        }
                    }
                }
                .onDelete { offsets in
                    let keywords = editor.group.keywords
                    let removed = Set(offsets.map { SGMessageFilterRule.identity(keywords[keywords.count - 1 - $0]) })
                    editor.update { $0.keywords.removeAll(where: { removed.contains(SGMessageFilterRule.identity($0)) }) }
                }
            }
        }
        .navigationBarTitle(Text(editor.group.name), displayMode: .inline)
        .navigationBarItems(trailing: EditButton())
        .onDisappear {
            wrapperController?.view.endEditing(true)
            if !editor.saveName(), let error = editor.error {
                onError(error)
            }
        }
    }

    private func addKeyword() {
        let keyword = isRegularExpression ? SGMessageFilterRule.regularExpressionPrefix + newKeyword : SGMessageFilterRule.normalized(newKeyword)
        guard !keyword.isEmpty else { return }
        if let error = SGMessageFilterRule.validationError(for: keyword) {
            onError(error)
            return
        }
        if editor.update({ $0.keywords.append(keyword) }) {
            newKeyword = ""
            isRegularExpression = false
        } else if let error = editor.error {
            onError(error)
        }
    }
}

@available(iOS 13.0, *)
public func sgMessageFilterController(presentationData: PresentationData? = nil) -> ViewController {
    let theme = presentationData?.theme ?? (UITraitCollection.current.userInterfaceStyle == .dark ? defaultDarkColorPresentationTheme : defaultPresentationTheme)
    let strings = presentationData?.strings ?? defaultPresentationStrings

    let legacyController = LegacySwiftUIController(
        presentation: .navigation,
        theme: theme,
        strings: strings
    )
    // Status bar color will break if theme changed
    legacyController.statusBar.statusBarStyle = theme.rootController
        .statusBarStyle.style
    legacyController.displayNavigationBar = false
    let swiftUIView = SGSwiftUIView<MessageFilterView>(
        legacyController: legacyController,
        content: {
            MessageFilterView(wrapperController: legacyController, theme: theme)
        }
    )
    let controller = UIHostingController(rootView: swiftUIView, ignoreSafeArea: true)
    legacyController.bind(controller: controller)

    return legacyController
}
