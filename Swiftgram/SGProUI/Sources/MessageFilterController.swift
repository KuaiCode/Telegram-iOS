import Foundation
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

    var body: some View {
        HStack {
            TextField("MessageFilter.InputPlaceholder".i18n(lang), text: $newKeyword)
                .disableAutocorrection(true)
                .autocapitalization(.none)
                .keyboardType(.default)
                .modifier(MessageFilterKeywordInputFieldModifier(newKeyword: $newKeyword, onAdd: onAdd))
                
            
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .accentColor)
                    .imageScale(.large)
            }
            .accessibility(label: Text("MessageFilter.AddKeyword".i18n(lang)))
            .disabled(newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    NavigationLink(destination: MessageFilterGroupView(group: group, onSave: updateGroup, onExport: { selected in
                        chooseExportFormat(SGMessageFilterConfiguration(matchingMode: configuration.matchingMode, groups: [selected]))
                    })) {
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
            if let error = SGSimpleSettings.shared.messageFilter.loadError {
                showError(error)
            }
        }
        .alert(isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Alert(title: Text("MessageFilter.Error".i18n(lang)), message: Text(errorMessage ?? ""), dismissButton: .default(Text("MessageFilter.OK".i18n(lang))))
        }
    }

    private func groupSummary(_ group: SGMessageFilterGroup) -> String {
        let action = (group.action == .dim ? "MessageFilter.Action.Dim" : "MessageFilter.Action.Allow").i18n(lang)
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

    private func updateGroup(named name: String, with group: SGMessageFilterGroup) -> Bool {
        guard let index = configuration.groups.firstIndex(where: { $0.name == name }) else { return false }
        var updated = configuration
        updated.groups[index] = group
        guard save(updated) else { return false }
        SGSimpleSettings.shared.messageFilter.renameLastUsedGroup(from: name, to: group.name)
        return true
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
        let key: String
        if let error = error as? SGMessageFilterRuleFileError {
            switch error {
            case .fileTooLarge: key = "MessageFilter.Error.FileTooLarge"
            case .unsupportedFormat: key = "MessageFilter.Error.UnsupportedFormat"
            case .emptyGroupName: key = "MessageFilter.Error.EmptyGroupName"
            case .duplicateGroupName: key = "MessageFilter.Error.DuplicateGroupName"
            case .emptyKeyword: key = "MessageFilter.Error.EmptyKeyword"
            case .multilineKeyword: key = "MessageFilter.Error.MultilineKeyword"
            case .unreadableStoredConfiguration: key = "MessageFilter.Error.StoredConfiguration"
            case .invalidFile, .invalidGroupID, .duplicateGroupID: key = "MessageFilter.Error.InvalidFile"
            }
            errorMessage = key.i18n(lang)
        } else {
            errorMessage = "MessageFilter.Error.FileAccess".i18n(lang) + "\n" + error.localizedDescription
        }
    }
}

@available(iOS 13.0, *)
private struct MessageFilterGroupView: View {
    @Environment(\.lang) var lang: String
    @State private var group: SGMessageFilterGroup
    @State private var savedName: String
    @State private var name: String
    @State private var newKeyword = ""
    let initialGroup: SGMessageFilterGroup
    let onSave: (String, SGMessageFilterGroup) -> Bool
    let onExport: (SGMessageFilterGroup) -> Void

    init(group: SGMessageFilterGroup, onSave: @escaping (String, SGMessageFilterGroup) -> Bool, onExport: @escaping (SGMessageFilterGroup) -> Void) {
        _group = State(initialValue: group)
        _savedName = State(initialValue: group.name)
        _name = State(initialValue: group.name)
        self.initialGroup = group
        self.onSave = onSave
        self.onExport = onExport
    }

    var body: some View {
        List {
            Section(header: Text("MessageFilter.GroupName".i18n(lang))) {
                TextField("MessageFilter.GroupName".i18n(lang), text: $name, onCommit: rename)
                    .disableAutocorrection(true)
                Button("MessageFilter.SaveName".i18n(lang), action: rename)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == savedName)
                Picker("MessageFilter.Action".i18n(lang), selection: Binding(get: { group.action }, set: { action in
                    var updated = group
                    updated.action = action
                    update(updated)
                })) {
                    Text("MessageFilter.Action.Dim".i18n(lang)).tag(SGMessageFilterAction.dim)
                    Text("MessageFilter.Action.Allow".i18n(lang)).tag(SGMessageFilterAction.allow)
                }
            }
            Section {
                MessageFilterKeywordInputView(newKeyword: $newKeyword, onAdd: addKeyword)
                Button("MessageFilter.ExportGroup".i18n(lang)) { onExport(group) }
            }
            Section(header: Text("MessageFilter.Keywords.Title".i18n(lang))) {
                ForEach(group.keywords.reversed(), id: \.self) { keyword in
                    Text(keyword)
                }
                .onDelete { offsets in
                    var updated = group
                    updated.keywords.remove(atOffsets: IndexSet(offsets.map { group.keywords.count - 1 - $0 }))
                    update(updated)
                }
            }
        }
        .navigationBarTitle(group.name, displayMode: .inline)
        .navigationBarItems(trailing: EditButton())
        .onAppear {
            group = initialGroup
            savedName = initialGroup.name
            name = initialGroup.name
        }
    }

    private func update(_ updated: SGMessageFilterGroup) {
        if onSave(savedName, updated) {
            group = updated
            savedName = updated.name
        }
    }

    private func rename() {
        var updated = group
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.name.isEmpty else { return }
        update(updated)
        name = savedName
    }

    private func addKeyword() {
        let keyword = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !group.keywords.contains(keyword) else { return }
        var updated = group
        updated.keywords.append(keyword)
        update(updated)
        if group.keywords.contains(keyword) { newKeyword = "" }
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
