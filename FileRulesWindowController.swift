import AppKit
import ServiceManagement
import UniformTypeIdentifiers

private enum FileRulesFormError: LocalizedError {
    case conflictingExtensions([String])

    var errorDescription: String? {
        switch self {
        case .conflictingExtensions(let extensions):
            return "Choose only one behavior for: \(extensions.joined(separator: ", "))."
        }
    }
}

enum LaunchAtLoginAvailability: Equatable {
    case available
    case removableOnly(reason: String)
    case unavailable(reason: String)

    var allowsChanges: Bool {
        switch self {
        case .available, .removableOnly:
            return true
        case .unavailable:
            return false
        }
    }

    var allowsEnabling: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    var explanation: String? {
        switch self {
        case .available:
            return nil
        case let .removableOnly(reason), let .unavailable(reason):
            return reason
        }
    }
}

struct GeneralSettings: Equatable {
    var isEnabled: Bool
    var launchAtLogin: Bool
    var launchAtLoginRequiresApproval: Bool
    var launchAtLoginAvailability: LaunchAtLoginAvailability
    var showMenuBarIcon: Bool
}

private struct FileRulesFormSnapshot: Equatable {
    let defaultBehaviorIndex: Int
    let categoryIndexes: [FileCategory: Int]
    let keepClosedExtensions: String
    let allowFinderExtensions: String
}

private struct SettingsFormSnapshot: Equatable {
    let isEnabled: Bool
    let launchAtLogin: Bool
    let showMenuBarIcon: Bool
    let fileRules: FileRulesFormSnapshot
}

private final class SettingsContentView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var policy: FileBehaviorPolicy
    private var generalSettings: GeneralSettings
    private let onSave: (FileBehaviorPolicy, GeneralSettings) throws -> Void
    private var savedFormSnapshot: SettingsFormSnapshot?
    private var isClosingAfterConfirmation = false

    private let enabledCheckbox = NSButton(checkboxWithTitle: "Enable SilentAirDrop", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let launchAtLoginAvailabilityLabel = NSTextField(labelWithString: "")
    private let launchAtLoginApprovalRow = NSStackView()
    private let showMenuBarIconCheckbox = NSButton(checkboxWithTitle: "Show menu bar icon", target: nil, action: nil)
    private let defaultBehaviorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var categoryPopups: [FileCategory: NSPopUpButton] = [:]
    private let keepClosedExtensionsField = NSTextField()
    private let allowFinderExtensionsField = NSTextField()
    private let validationLabel = NSTextField(labelWithString: "")

    init(
        policy: FileBehaviorPolicy,
        generalSettings: GeneralSettings,
        onSave: @escaping (FileBehaviorPolicy, GeneralSettings) throws -> Void
    ) {
        self.policy = policy
        self.generalSettings = generalSettings
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 650, height: 700)
        let contentView = SettingsContentView(frame: NSRect(x: 0, y: 0, width: 650, height: 700))
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        super.init(window: window)
        window.delegate = self
        configureContent()
        window.initialFirstResponder = contentView
        loadControls(policy: policy, generalSettings: generalSettings)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible != true {
            loadControls(policy: policy, generalSettings: generalSettings)
        }
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(window?.contentView)
    }

    func update(policy: FileBehaviorPolicy, generalSettings: GeneralSettings) {
        guard window?.isVisible != true else {
            return
        }
        self.policy = policy
        self.generalSettings = generalSettings
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isClosingAfterConfirmation,
              let savedFormSnapshot,
              currentFormSnapshot() != savedFormSnapshot else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Your Settings changes have not been saved."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self, let sender else {
                return
            }
            if response == .alertFirstButtonReturn {
                self.loadControls(policy: self.policy, generalSettings: self.generalSettings)
                self.isClosingAfterConfirmation = true
                sender.close()
                self.isClosingAfterConfirmation = false
            } else {
                sender.makeKeyAndOrderFront(nil)
            }
        }
        return false
    }

    private func currentFileRulesSnapshot() -> FileRulesFormSnapshot {
        var categoryIndexes: [FileCategory: Int] = [:]
        for category in FileCategory.allCases {
            categoryIndexes[category] = categoryPopups[category]?.indexOfSelectedItem ?? 0
        }

        return FileRulesFormSnapshot(
            defaultBehaviorIndex: defaultBehaviorPopup.indexOfSelectedItem,
            categoryIndexes: categoryIndexes,
            keepClosedExtensions: keepClosedExtensionsField.stringValue,
            allowFinderExtensions: allowFinderExtensionsField.stringValue
        )
    }

    private func currentFormSnapshot() -> SettingsFormSnapshot {
        return SettingsFormSnapshot(
            isEnabled: enabledCheckbox.state == .on,
            launchAtLogin: launchAtLoginCheckbox.state == .on,
            showMenuBarIcon: showMenuBarIconCheckbox.state == .on,
            fileRules: currentFileRulesSnapshot()
        )
    }

    private func configureContent() {
        guard let contentView = window?.contentView else {
            return
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
        ])

        stack.addArrangedSubview(makeSectionLabel("General"))

        let generalControls = NSStackView(views: [
            enabledCheckbox,
            launchAtLoginCheckbox,
            launchAtLoginAvailabilityLabel,
            launchAtLoginApprovalRow,
            showMenuBarIconCheckbox
        ])
        generalControls.orientation = .vertical
        generalControls.alignment = .leading
        generalControls.spacing = 6
        stack.addArrangedSubview(generalControls)

        let approvalLabel = makeLabel("Approval required in System Settings")
        approvalLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        approvalLabel.textColor = .systemOrange
        let openLoginItemsButton = NSButton(
            title: "Open Login Items…",
            target: self,
            action: #selector(openLoginItemsSettings)
        )
        openLoginItemsButton.bezelStyle = .inline
        launchAtLoginApprovalRow.orientation = .horizontal
        launchAtLoginApprovalRow.alignment = .centerY
        launchAtLoginApprovalRow.spacing = 8
        launchAtLoginApprovalRow.addArrangedSubview(approvalLabel)
        launchAtLoginApprovalRow.addArrangedSubview(openLoginItemsButton)
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginSelectionChanged)
        launchAtLoginAvailabilityLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        launchAtLoginAvailabilityLabel.textColor = .secondaryLabelColor
        launchAtLoginAvailabilityLabel.maximumNumberOfLines = 0
        launchAtLoginAvailabilityLabel.lineBreakMode = .byWordWrapping
        launchAtLoginAvailabilityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        launchAtLoginAvailabilityLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560).isActive = true

        let menuBarHelpLabel = makeLabel(
            "macOS may ask you to approve Launch at Login in System Settings. If you hide the menu bar icon, launch SilentAirDrop again to restore it."
        )
        menuBarHelpLabel.textColor = .secondaryLabelColor
        menuBarHelpLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(menuBarHelpLabel)

        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(makeSectionLabel("File rules"))

        let explanationLabel = makeLabel(
            "Choose when Finder stays closed for new items detected directly in Downloads."
        )
        explanationLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(explanationLabel)
        explanationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        defaultBehaviorPopup.addItems(withTitles: FileHandlingBehavior.allCases.map(\.title))
        defaultBehaviorPopup.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let defaultGrid = makeGrid(rows: [
            [makeTrailingLabel("Default for unmatched files:"), defaultBehaviorPopup]
        ])
        stack.addArrangedSubview(defaultGrid)

        stack.addArrangedSubview(makeSectionLabel("File type overrides"))

        var categoryControls: [(label: NSTextField, popup: NSPopUpButton)] = []
        for category in FileCategory.allCases {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: [
                "Use Default",
                FileHandlingBehavior.keepFinderClosed.title,
                FileHandlingBehavior.allowFinder.title
            ])
            popup.widthAnchor.constraint(equalToConstant: 170).isActive = true
            categoryPopups[category] = popup
            categoryControls.append((makeTrailingLabel("\(category.title):"), popup))
        }

        var categoryRows: [[NSView]] = []
        for index in stride(from: 0, to: categoryControls.count, by: 2) {
            let first = categoryControls[index]
            if index + 1 < categoryControls.count {
                let second = categoryControls[index + 1]
                categoryRows.append([first.label, first.popup, second.label, second.popup])
            } else {
                categoryRows.append([first.label, first.popup, NSView(), NSView()])
            }
        }

        let categoryGrid = makeGrid(rows: categoryRows)
        stack.addArrangedSubview(categoryGrid)

        stack.addArrangedSubview(makeSectionLabel("Exact extension overrides"))

        keepClosedExtensionsField.placeholderString = "jpg, png, tar.gz"
        allowFinderExtensionsField.placeholderString = "dmg, pkg"
        keepClosedExtensionsField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        allowFinderExtensionsField.widthAnchor.constraint(equalToConstant: 340).isActive = true

        let extensionGrid = makeGrid(rows: [
            [makeTrailingLabel("Keep Finder closed:"), keepClosedExtensionsField],
            [makeTrailingLabel("Let Finder open:"), allowFinderExtensionsField]
        ])
        stack.addArrangedSubview(extensionGrid)

        let helpLabel = makeLabel(
            "Extensions are case-insensitive and take priority over file types. Compound extensions such as tar.gz are supported. For a mixed transfer, Finder opens if any item is configured to open."
        )
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(helpLabel)
        helpLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        validationLabel.textColor = .systemRed
        validationLabel.maximumNumberOfLines = 2
        validationLabel.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(validationLabel)
        validationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let resetButton = NSButton(title: "Reset File Rules", target: self, action: #selector(resetFileRules))
        let importButton = NSButton(title: "Import…", target: self, action: #selector(importRules))
        importButton.toolTip = "Import File Rules from a JSON file"
        let exportButton = NSButton(title: "Export…", target: self, action: #selector(exportRules))
        exportButton.toolTip = "Export the File Rules currently shown"
        let githubButton = NSButton(title: "View on GitHub", target: self, action: #selector(openGitHub))
        githubButton.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
        githubButton.imagePosition = .imageTrailing
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(
            views: [resetButton, importButton, exportButton, githubButton, spacer, cancelButton, saveButton]
        )
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        stack.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeGrid(rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 7
        grid.columnSpacing = 12
        for index in 0..<grid.numberOfColumns {
            grid.column(at: index).xPlacement = index.isMultiple(of: 2) ? .trailing : .leading
        }
        return grid
    }

    private func makeLabel(_ text: String, font: NSFont? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func makeTrailingLabel(_ text: String) -> NSTextField {
        let label = makeLabel(text)
        label.alignment = .right
        return label
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        return makeLabel(text, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
    }

    private func loadControls(policy: FileBehaviorPolicy, generalSettings: GeneralSettings) {
        enabledCheckbox.state = generalSettings.isEnabled ? .on : .off
        launchAtLoginCheckbox.state = generalSettings.launchAtLogin ? .on : .off
        launchAtLoginCheckbox.isEnabled = generalSettings.launchAtLoginAvailability.allowsChanges
        launchAtLoginAvailabilityLabel.stringValue = generalSettings.launchAtLoginAvailability.explanation ?? ""
        launchAtLoginAvailabilityLabel.isHidden = generalSettings.launchAtLoginAvailability.explanation == nil
        launchAtLoginApprovalRow.isHidden = !generalSettings.launchAtLoginRequiresApproval
        showMenuBarIconCheckbox.state = generalSettings.showMenuBarIcon ? .on : .off
        loadFileRuleControls(from: policy)
        savedFormSnapshot = currentFormSnapshot()
    }

    private func loadFileRuleControls(from policy: FileBehaviorPolicy) {
        defaultBehaviorPopup.selectItem(at: policy.defaultBehavior == .keepFinderClosed ? 0 : 1)

        for category in FileCategory.allCases {
            let selectedIndex: Int
            switch policy.categoryOverrides[category] {
            case .keepFinderClosed:
                selectedIndex = 1
            case .allowFinder:
                selectedIndex = 2
            case nil:
                selectedIndex = 0
            }
            categoryPopups[category]?.selectItem(at: selectedIndex)
        }

        let keepClosedExtensions = policy.extensionOverrides
            .filter { $0.value == .keepFinderClosed }
            .map(\.key)
            .sorted()
        let allowFinderExtensions = policy.extensionOverrides
            .filter { $0.value == .allowFinder }
            .map(\.key)
            .sorted()

        keepClosedExtensionsField.stringValue = keepClosedExtensions.joined(separator: ", ")
        allowFinderExtensionsField.stringValue = allowFinderExtensions.joined(separator: ", ")
        validationLabel.stringValue = ""
    }

    private func policyFromRuleControls() throws -> FileBehaviorPolicy {
        let keepClosedExtensions = try FileBehaviorPolicy.parseExtensionList(
            keepClosedExtensionsField.stringValue
        )
        let allowFinderExtensions = try FileBehaviorPolicy.parseExtensionList(
            allowFinderExtensionsField.stringValue
        )
        let conflicts = keepClosedExtensions.intersection(allowFinderExtensions).sorted()
        guard conflicts.isEmpty else {
            throw FileRulesFormError.conflictingExtensions(conflicts)
        }

        let defaultBehavior: FileHandlingBehavior = defaultBehaviorPopup.indexOfSelectedItem == 1
            ? .allowFinder
            : .keepFinderClosed

        var categoryOverrides: [FileCategory: FileHandlingBehavior] = [:]
        for category in FileCategory.allCases {
            switch categoryPopups[category]?.indexOfSelectedItem {
            case 1:
                categoryOverrides[category] = .keepFinderClosed
            case 2:
                categoryOverrides[category] = .allowFinder
            default:
                break
            }
        }

        var extensionOverrides: [String: FileHandlingBehavior] = [:]
        for fileExtension in keepClosedExtensions {
            extensionOverrides[fileExtension] = .keepFinderClosed
        }
        for fileExtension in allowFinderExtensions {
            extensionOverrides[fileExtension] = .allowFinder
        }

        return FileBehaviorPolicy(
            defaultBehavior: defaultBehavior,
            categoryOverrides: categoryOverrides,
            extensionOverrides: extensionOverrides
        )
    }

    private func showRuleError(_ error: Error, prefix: String? = nil) {
        validationLabel.textColor = .systemRed
        if let prefix {
            validationLabel.stringValue = "\(prefix): \(error.localizedDescription)"
        } else {
            validationLabel.stringValue = error.localizedDescription
        }
    }

    private func showRuleMessage(_ message: String) {
        validationLabel.textColor = .secondaryLabelColor
        validationLabel.stringValue = message
    }

    private func stageImportedRules(_ importedPolicy: FileBehaviorPolicy, fileName: String) {
        loadFileRuleControls(from: importedPolicy)
        let needsSave = currentFileRulesSnapshot() != savedFormSnapshot?.fileRules
        if needsSave {
            showRuleMessage("Imported \(fileName). Review the rules and click Save to apply them.")
        } else {
            showRuleMessage("Imported \(fileName). These rules already match your saved File Rules.")
        }
    }

    private func confirmAndStageImportedRules(
        _ importedPolicy: FileBehaviorPolicy,
        fileName: String
    ) {
        guard let window else {
            return
        }

        let hasUnsavedRuleChanges = currentFileRulesSnapshot() != savedFormSnapshot?.fileRules
        guard hasUnsavedRuleChanges else {
            stageImportedRules(importedPolicy, fileName: fileName)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Replace unsaved File Rules?"
        alert.informativeText = "Importing \(fileName) will replace the File Rules currently shown. General settings will not change."
        alert.addButton(withTitle: "Replace Rules")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.stageImportedRules(importedPolicy, fileName: fileName)
        }
    }

    @objc private func resetFileRules() {
        loadFileRuleControls(from: .default)
    }

    @objc private func importRules() {
        guard let window else {
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import File Rules"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK,
                  let self,
                  let url = panel.url else {
                return
            }

            do {
                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
                if let fileSize = resourceValues.fileSize,
                   fileSize > FileBehaviorPolicy.maximumRulesTransferSize {
                    throw FileRulesTransferError.fileTooLarge
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let importedPolicy = try FileBehaviorPolicy.importedRules(from: data)
                self.confirmAndStageImportedRules(
                    importedPolicy,
                    fileName: url.lastPathComponent
                )
            } catch {
                self.showRuleError(error, prefix: "Couldn’t import rules")
            }
        }
    }

    @objc private func exportRules() {
        let exportedData: Data
        do {
            exportedData = try policyFromRuleControls().exportedRulesData()
        } catch {
            showRuleError(error)
            return
        }

        guard let window else {
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export File Rules"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "SilentAirDrop File Rules.json"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK,
                  let self,
                  let url = panel.url else {
                return
            }

            do {
                try exportedData.write(to: url, options: .atomic)
                self.showRuleMessage("Exported File Rules to \(url.lastPathComponent).")
            } catch {
                self.showRuleError(error, prefix: "Couldn’t export rules")
            }
        }
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func openGitHub() {
        guard let url = URL(string: "https://github.com/gaptriko/SilentAirDrop") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func launchAtLoginSelectionChanged() {
        launchAtLoginApprovalRow.isHidden = launchAtLoginCheckbox.state != .on
            || !generalSettings.launchAtLoginRequiresApproval
    }

    @objc private func save() {
        do {
            let updatedPolicy = try policyFromRuleControls()
            let updatedGeneralSettings = GeneralSettings(
                isEnabled: enabledCheckbox.state == .on,
                launchAtLogin: launchAtLoginCheckbox.state == .on,
                launchAtLoginRequiresApproval: generalSettings.launchAtLoginRequiresApproval,
                launchAtLoginAvailability: generalSettings.launchAtLoginAvailability,
                showMenuBarIcon: showMenuBarIconCheckbox.state == .on
            )

            try onSave(updatedPolicy, updatedGeneralSettings)
            policy = updatedPolicy
            generalSettings = updatedGeneralSettings
            savedFormSnapshot = currentFormSnapshot()
            window?.close()
        } catch {
            showRuleError(error)
        }
    }
}
