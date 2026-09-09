import Foundation
import UniformTypeIdentifiers

enum FileHandlingBehavior: String, Codable, CaseIterable {
    case keepFinderClosed
    case allowFinder

    var title: String {
        switch self {
        case .keepFinderClosed:
            return "Keep Finder closed"
        case .allowFinder:
            return "Let Finder open"
        }
    }
}

enum FileCategory: String, Codable, CaseIterable {
    case images
    case video
    case audio
    case pdfs
    case archives
    case documents
    case appsAndDiskImages
    case folders
    case other

    var title: String {
        switch self {
        case .images:
            return "Images"
        case .video:
            return "Video"
        case .audio:
            return "Audio"
        case .pdfs:
            return "PDFs"
        case .archives:
            return "Archives"
        case .documents:
            return "Documents"
        case .appsAndDiskImages:
            return "Apps & Disk Images"
        case .folders:
            return "Folders"
        case .other:
            return "Other files"
        }
    }
}

struct FileCandidate {
    let url: URL
    let isDirectory: Bool
    let contentType: UTType?

    init(url: URL, isDirectory: Bool, contentType: UTType? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.contentType = contentType
    }
}

enum FileExtensionListError: LocalizedError {
    case invalidExtension(String)

    var errorDescription: String? {
        switch self {
        case .invalidExtension(let value):
            return "\(value) is not a valid extension. Enter extensions such as jpg, pdf, or tar.gz."
        }
    }
}

enum FileRulesTransferError: LocalizedError, Equatable {
    case fileTooLarge
    case invalidFile
    case wrongFormat
    case unsupportedVersion(Int)
    case unknownCategory(String)
    case unknownBehavior(String)
    case invalidExtension(String)
    case conflictingExtension(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "The File Rules data is too large to import or export."
        case .invalidFile:
            return "The selected file is not a valid SilentAirDrop File Rules export."
        case .wrongFormat:
            return "The selected JSON file was not exported by SilentAirDrop File Rules."
        case .unsupportedVersion(let version):
            return "This rules file uses unsupported format version \(version)."
        case .unknownCategory(let category):
            return "The rules file contains an unknown file category: \(category)."
        case .unknownBehavior(let behavior):
            return "The rules file contains an unknown behavior: \(behavior)."
        case .invalidExtension(let fileExtension):
            return "The rules file contains an invalid extension: \(fileExtension)."
        case .conflictingExtension(let fileExtension):
            return "The rules file assigns conflicting behaviors to extension \(fileExtension)."
        }
    }
}

struct FileBehaviorPolicy: Equatable {
    static let storageKey = "SilentAirDropFileBehaviorPolicyV1"
    static let exportedRulesFormat = "com.gaptriko.SilentAirDrop.file-rules"
    static let exportedRulesVersion = 1
    static let maximumRulesTransferSize = 1_048_576

    var defaultBehavior: FileHandlingBehavior
    var categoryOverrides: [FileCategory: FileHandlingBehavior]
    var extensionOverrides: [String: FileHandlingBehavior]

    static let `default` = FileBehaviorPolicy(
        defaultBehavior: .keepFinderClosed,
        categoryOverrides: [:],
        extensionOverrides: [:]
    )

    init(
        defaultBehavior: FileHandlingBehavior,
        categoryOverrides: [FileCategory: FileHandlingBehavior],
        extensionOverrides: [String: FileHandlingBehavior]
    ) {
        self.defaultBehavior = defaultBehavior
        self.categoryOverrides = categoryOverrides

        var normalizedOverrides: [String: FileHandlingBehavior] = [:]
        for (fileExtension, behavior) in extensionOverrides {
            if let normalized = Self.normalizeExtension(fileExtension) {
                normalizedOverrides[normalized] = behavior
            }
        }
        self.extensionOverrides = normalizedOverrides
    }

    func behavior(for candidate: FileCandidate) -> FileHandlingBehavior {
        if let extensionBehavior = matchingExtensionBehavior(for: candidate.url.lastPathComponent) {
            return extensionBehavior
        }

        let category = category(for: candidate)
        return categoryOverrides[category] ?? defaultBehavior
    }

    /// A single Finder window represents the whole transfer. An explicit
    /// "Let Finder open" result therefore wins for mixed batches.
    func behavior(for candidates: [FileCandidate]) -> FileHandlingBehavior {
        guard !candidates.isEmpty else {
            return defaultBehavior
        }

        return candidates.contains(where: { behavior(for: $0) == .allowFinder })
            ? .allowFinder
            : .keepFinderClosed
    }

    func category(for candidate: FileCandidate) -> FileCategory {
        let fileExtension = candidate.url.pathExtension.lowercased()
        let contentType = resolvedContentType(for: candidate)

        if Self.applicationExtensions.contains(fileExtension)
            || contentType?.conforms(to: .applicationBundle) == true
            || contentType?.conforms(to: .diskImage) == true {
            return .appsAndDiskImages
        }

        if candidate.isDirectory && Self.documentPackageExtensions.contains(fileExtension) {
            return .documents
        }

        if candidate.isDirectory {
            return .folders
        }

        if fileExtension == "pdf" || contentType?.conforms(to: .pdf) == true {
            return .pdfs
        }

        if Self.imageExtensions.contains(fileExtension)
            || contentType?.conforms(to: .image) == true
            || Self.knownImageTypeIdentifiers.contains(contentType?.identifier ?? "") {
            return .images
        }

        if Self.videoExtensions.contains(fileExtension)
            || contentType?.conforms(to: .movie) == true
            || contentType?.conforms(to: .video) == true {
            return .video
        }

        if Self.audioExtensions.contains(fileExtension)
            || contentType?.conforms(to: .audio) == true {
            return .audio
        }

        if Self.archiveExtensions.contains(fileExtension)
            || contentType?.conforms(to: .archive) == true {
            return .archives
        }

        if Self.documentExtensions.contains(fileExtension)
            || contentType?.conforms(to: .text) == true
            || contentType?.conforms(to: .sourceCode) == true
            || contentType?.conforms(to: .spreadsheet) == true
            || contentType?.conforms(to: .presentation) == true {
            return .documents
        }

        return .other
    }

    static func parseExtensionList(_ text: String) throws -> Set<String> {
        let rawValues = text.split(whereSeparator: { character in
            character == "," || character == ";" || character.isWhitespace
        })

        var extensions = Set<String>()
        for rawValue in rawValues {
            let original = String(rawValue)
            guard let normalized = normalizeExtension(original) else {
                throw FileExtensionListError.invalidExtension(original)
            }
            extensions.insert(normalized)
        }
        return extensions
    }

    static func normalizeExtension(_ value: String) -> String? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.hasPrefix("*.") {
            normalized.removeFirst(2)
        } else if normalized.hasPrefix(".") {
            normalized.removeFirst()
        }

        let invalidCharacters = CharacterSet(charactersIn: "/\\*?,;")
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        let hasInvalidCharacter = normalized.rangeOfCharacter(from: invalidCharacters) != nil
        let hasEmptyComponent = normalized
            .split(separator: ".", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty })

        guard !normalized.isEmpty,
              !hasInvalidCharacter,
              !hasEmptyComponent else {
            return nil
        }

        return normalized
    }

    static func load(from defaults: UserDefaults = .standard) -> FileBehaviorPolicy {
        guard let data = defaults.data(forKey: storageKey) else {
            return .default
        }
        return decoded(from: data) ?? .default
    }

    static func decoded(from data: Data) -> FileBehaviorPolicy? {
        guard let storedPolicy = try? JSONDecoder().decode(StoredFileBehaviorPolicy.self, from: data),
              storedPolicy.version == 1 else {
            return nil
        }

        var categoryOverrides: [FileCategory: FileHandlingBehavior] = [:]
        for (categoryName, behavior) in storedPolicy.categoryOverrides {
            if let category = FileCategory(rawValue: categoryName) {
                categoryOverrides[category] = behavior
            }
        }

        return FileBehaviorPolicy(
            defaultBehavior: storedPolicy.defaultBehavior,
            categoryOverrides: categoryOverrides,
            extensionOverrides: storedPolicy.extensionOverrides
        )
    }

    func encoded() -> Data? {
        let storedPolicy = StoredFileBehaviorPolicy(
            version: 1,
            defaultBehavior: defaultBehavior,
            categoryOverrides: Dictionary(
                uniqueKeysWithValues: categoryOverrides.map { ($0.key.rawValue, $0.value) }
            ),
            extensionOverrides: extensionOverrides
        )
        return try? JSONEncoder().encode(storedPolicy)
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = encoded() else {
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    func exportedRulesData() throws -> Data {
        let portablePolicy = PortableFileBehaviorPolicy(
            format: Self.exportedRulesFormat,
            version: Self.exportedRulesVersion,
            defaultBehavior: defaultBehavior.rawValue,
            categoryOverrides: Dictionary(
                uniqueKeysWithValues: categoryOverrides.map {
                    ($0.key.rawValue, $0.value.rawValue)
                }
            ),
            extensionOverrides: Dictionary(
                uniqueKeysWithValues: extensionOverrides.map {
                    ($0.key, $0.value.rawValue)
                }
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(portablePolicy)
        guard data.count + 1 <= Self.maximumRulesTransferSize else {
            throw FileRulesTransferError.fileTooLarge
        }
        data.append(0x0A)
        return data
    }

    static func importedRules(from data: Data) throws -> FileBehaviorPolicy {
        guard data.count <= maximumRulesTransferSize else {
            throw FileRulesTransferError.fileTooLarge
        }

        let decoder = JSONDecoder()
        let header: PortableFileBehaviorPolicyHeader
        do {
            header = try decoder.decode(PortableFileBehaviorPolicyHeader.self, from: data)
        } catch {
            throw FileRulesTransferError.invalidFile
        }

        guard header.format == exportedRulesFormat else {
            throw FileRulesTransferError.wrongFormat
        }
        guard header.version == exportedRulesVersion else {
            throw FileRulesTransferError.unsupportedVersion(header.version)
        }

        let portablePolicy: PortableFileBehaviorPolicy
        do {
            portablePolicy = try decoder.decode(PortableFileBehaviorPolicy.self, from: data)
        } catch {
            throw FileRulesTransferError.invalidFile
        }

        guard let defaultBehavior = FileHandlingBehavior(rawValue: portablePolicy.defaultBehavior) else {
            throw FileRulesTransferError.unknownBehavior(portablePolicy.defaultBehavior)
        }

        var categoryOverrides: [FileCategory: FileHandlingBehavior] = [:]
        for (categoryName, behaviorName) in portablePolicy.categoryOverrides {
            guard let category = FileCategory(rawValue: categoryName) else {
                throw FileRulesTransferError.unknownCategory(categoryName)
            }
            guard let behavior = FileHandlingBehavior(rawValue: behaviorName) else {
                throw FileRulesTransferError.unknownBehavior(behaviorName)
            }
            categoryOverrides[category] = behavior
        }

        var extensionOverrides: [String: FileHandlingBehavior] = [:]
        for (extensionName, behaviorName) in portablePolicy.extensionOverrides.sorted(by: { $0.key < $1.key }) {
            guard let behavior = FileHandlingBehavior(rawValue: behaviorName) else {
                throw FileRulesTransferError.unknownBehavior(behaviorName)
            }
            guard let normalizedExtension = normalizeExtension(extensionName) else {
                throw FileRulesTransferError.invalidExtension(extensionName)
            }
            if let existingBehavior = extensionOverrides[normalizedExtension],
               existingBehavior != behavior {
                throw FileRulesTransferError.conflictingExtension(normalizedExtension)
            }
            extensionOverrides[normalizedExtension] = behavior
        }

        return FileBehaviorPolicy(
            defaultBehavior: defaultBehavior,
            categoryOverrides: categoryOverrides,
            extensionOverrides: extensionOverrides
        )
    }

    private func matchingExtensionBehavior(for fileName: String) -> FileHandlingBehavior? {
        let lowercaseName = fileName.lowercased()
        let matchingExtension = extensionOverrides.keys
            .filter { lowercaseName.hasSuffix(".\($0)") }
            .max(by: { $0.count < $1.count })

        guard let matchingExtension else {
            return nil
        }
        return extensionOverrides[matchingExtension]
    }

    private func resolvedContentType(for candidate: FileCandidate) -> UTType? {
        if let contentType = candidate.contentType {
            return contentType
        }

        if let resourceValues = try? candidate.url.resourceValues(forKeys: [.contentTypeKey]),
           let contentType = resourceValues.contentType {
            return contentType
        }

        let fileExtension = candidate.url.pathExtension
        guard !fileExtension.isEmpty else {
            return nil
        }
        return UTType(filenameExtension: fileExtension)
    }

    private static let applicationExtensions: Set<String> = [
        "app", "dmg", "iso", "mpkg", "pkg"
    ]

    private static let imageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "ico", "jpeg", "jpg", "png", "raw", "svg", "tif", "tiff", "webp"
    ]

    private static let videoExtensions: Set<String> = [
        "3gp", "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm", "wmv"
    ]

    private static let audioExtensions: Set<String> = [
        "aac", "aiff", "alac", "flac", "m4a", "mp3", "ogg", "opus", "wav", "wma"
    ]

    private static let knownImageTypeIdentifiers: Set<String> = [
        UTType.bmp.identifier,
        UTType.gif.identifier,
        UTType.heic.identifier,
        UTType.jpeg.identifier,
        UTType.png.identifier,
        UTType.svg.identifier,
        UTType.tiff.identifier
    ]

    private static let archiveExtensions: Set<String> = [
        "7z", "bz2", "gz", "rar", "tar", "tbz", "tbz2", "tgz", "txz", "xz", "zip"
    ]

    private static let documentExtensions: Set<String> = [
        "csv", "doc", "docx", "htm", "html", "json", "key", "markdown", "md", "numbers",
        "odp", "ods", "odt", "pages", "ppt", "pptx", "rtf", "rtfd", "tex", "tsv", "txt",
        "xls", "xlsx", "xml", "yaml", "yml"
    ]

    private static let documentPackageExtensions: Set<String> = [
        "key", "numbers", "pages", "rtfd"
    ]
}

private struct StoredFileBehaviorPolicy: Codable {
    let version: Int
    let defaultBehavior: FileHandlingBehavior
    let categoryOverrides: [String: FileHandlingBehavior]
    let extensionOverrides: [String: FileHandlingBehavior]
}

private struct PortableFileBehaviorPolicyHeader: Decodable {
    let format: String
    let version: Int
}

private struct PortableFileBehaviorPolicy: Codable {
    let format: String
    let version: Int
    let defaultBehavior: String
    let categoryOverrides: [String: String]
    let extensionOverrides: [String: String]

    private enum CodingKeys: String, CodingKey {
        case format
        case version
        case defaultBehavior
        case categoryOverrides
        case extensionOverrides
    }

    init(
        format: String,
        version: Int,
        defaultBehavior: String,
        categoryOverrides: [String: String],
        extensionOverrides: [String: String]
    ) {
        self.format = format
        self.version = version
        self.defaultBehavior = defaultBehavior
        self.categoryOverrides = categoryOverrides
        self.extensionOverrides = extensionOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        defaultBehavior = try container.decode(String.self, forKey: .defaultBehavior)
        categoryOverrides = try container.decodeIfPresent(
            [String: String].self,
            forKey: .categoryOverrides
        ) ?? [:]
        extensionOverrides = try container.decodeIfPresent(
            [String: String].self,
            forKey: .extensionOverrides
        ) ?? [:]
    }
}
