import Foundation
import UniformTypeIdentifiers

private var failureCount = 0
private var checkCount = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checkCount += 1
    if !condition() {
        failureCount += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func candidate(
    _ fileName: String,
    isDirectory: Bool = false,
    contentType: UTType? = nil
) -> FileCandidate {
    return FileCandidate(
        url: URL(fileURLWithPath: "/tmp/SilentAirDropTests/\(fileName)"),
        isDirectory: isDirectory,
        contentType: contentType
    )
}

let defaultPolicy = FileBehaviorPolicy.default
expect(
    defaultPolicy.behavior(for: candidate("unknown-file")) == .keepFinderClosed,
    "the default policy must preserve the existing keep-closed behavior"
)

let allowByDefault = FileBehaviorPolicy(
    defaultBehavior: .allowFinder,
    categoryOverrides: [:],
    extensionOverrides: [:]
)
expect(
    allowByDefault.behavior(for: candidate("unknown-file")) == .allowFinder,
    "unmatched files must use the configured default"
)

let uppercaseExtensionPolicy = FileBehaviorPolicy(
    defaultBehavior: .keepFinderClosed,
    categoryOverrides: [:],
    extensionOverrides: ["dmg": .allowFinder]
)
expect(
    uppercaseExtensionPolicy.behavior(for: candidate("Tool.DMG")) == .allowFinder,
    "extension rules must be case-insensitive"
)

let compoundExtensionPolicy = FileBehaviorPolicy(
    defaultBehavior: .keepFinderClosed,
    categoryOverrides: [:],
    extensionOverrides: ["gz": .keepFinderClosed, "tar.gz": .allowFinder]
)
expect(
    compoundExtensionPolicy.behavior(for: candidate("backup.tar.gz")) == .allowFinder,
    "the longest matching compound extension must win"
)

let extensionPrecedencePolicy = FileBehaviorPolicy(
    defaultBehavior: .keepFinderClosed,
    categoryOverrides: [.images: .keepFinderClosed],
    extensionOverrides: ["gif": .allowFinder]
)
expect(
    extensionPrecedencePolicy.behavior(
        for: candidate("animation.gif", contentType: .gif)
    ) == .allowFinder,
    "an exact extension must override a broader file type"
)

expect(
    defaultPolicy.category(for: candidate("photo.bin", contentType: .jpeg)) == .images,
    "UTType image conformance must classify images"
)
expect(
    defaultPolicy.category(for: candidate("clip.mp4")) == .video,
    "video extensions must classify as video"
)
expect(
    defaultPolicy.category(for: candidate("song.mp3")) == .audio,
    "audio extensions must classify as audio"
)
expect(
    defaultPolicy.category(for: candidate("report.PDF")) == .pdfs,
    "PDF matching must be case-insensitive"
)
expect(
    defaultPolicy.category(for: candidate("archive.zip")) == .archives,
    "archives must classify through UTType or their extension"
)
expect(
    defaultPolicy.category(for: candidate("proposal.docx")) == .documents,
    "common office formats must classify as documents"
)
expect(
    defaultPolicy.category(for: candidate("Installer.dmg")) == .appsAndDiskImages,
    "disk images must have their own category"
)
expect(
    defaultPolicy.category(for: candidate("Project", isDirectory: true)) == .folders,
    "directories must classify as folders"
)
expect(
    defaultPolicy.category(for: candidate("Deck.key", isDirectory: true)) == .documents,
    "document packages must classify as documents instead of generic folders"
)
expect(
    defaultPolicy.category(for: candidate("extensionless")) == .other,
    "unrecognized extensionless files must classify as other"
)

let mixedBatchPolicy = FileBehaviorPolicy(
    defaultBehavior: .keepFinderClosed,
    categoryOverrides: [:],
    extensionOverrides: ["dmg": .allowFinder]
)
expect(
    mixedBatchPolicy.behavior(for: [candidate("photo.jpg"), candidate("Tool.dmg")]) == .allowFinder,
    "Let Finder open must win for a mixed transfer"
)
expect(
    mixedBatchPolicy.behavior(for: [candidate("photo.jpg"), candidate("notes.txt")]) == .keepFinderClosed,
    "a fully keep-closed batch must remain closed"
)

do {
    let parsed = try FileBehaviorPolicy.parseExtensionList(".JPG, *.tar.gz; pdf")
    expect(parsed == Set(["jpg", "tar.gz", "pdf"]), "extension input must normalize common notation")
} catch {
    expect(false, "valid extension input unexpectedly failed: \(error)")
}

do {
    _ = try FileBehaviorPolicy.parseExtensionList("bad/path")
    expect(false, "path-like extension input must be rejected")
} catch {
    expect(true, "invalid extension input was rejected")
}

let persistedPolicy = FileBehaviorPolicy(
    defaultBehavior: .allowFinder,
    categoryOverrides: [.archives: .keepFinderClosed, .images: .allowFinder],
    extensionOverrides: ["tar.gz": .keepFinderClosed, "DMG": .allowFinder]
)
if let encodedPolicy = persistedPolicy.encoded(),
   let decodedPolicy = FileBehaviorPolicy.decoded(from: encodedPolicy) {
    expect(decodedPolicy == persistedPolicy, "file rules must round-trip through persisted storage")
} else {
    expect(false, "a valid file policy could not be encoded and decoded")
}
expect(
    FileBehaviorPolicy.decoded(from: Data("not-json".utf8)) == nil,
    "corrupt persisted rules must be rejected so the app can use defaults"
)

private func expectRulesImportFailure(_ json: String, _ message: String) {
    do {
        _ = try FileBehaviorPolicy.importedRules(from: Data(json.utf8))
        expect(false, message)
    } catch {
        expect(true, message)
    }
}

let exportedRulesPolicy = FileBehaviorPolicy(
    defaultBehavior: .allowFinder,
    categoryOverrides: [
        .images: .keepFinderClosed,
        .archives: .allowFinder,
        .folders: .keepFinderClosed
    ],
    extensionOverrides: [
        "jpg": .allowFinder,
        "tar.gz": .keepFinderClosed
    ]
)

do {
    let exportedData = try exportedRulesPolicy.exportedRulesData()
    let importedPolicy = try FileBehaviorPolicy.importedRules(from: exportedData)
    expect(importedPolicy == exportedRulesPolicy, "exported file rules must round-trip without changes")

    if let document = try JSONSerialization.jsonObject(with: exportedData) as? [String: Any] {
        let expectedKeys: Set<String> = [
            "format", "version", "defaultBehavior", "categoryOverrides", "extensionOverrides"
        ]
        expect(Set(document.keys) == expectedKeys, "rule exports must contain only the versioned rule schema")
        expect(
            document["format"] as? String == "com.gaptriko.SilentAirDrop.file-rules",
            "rule exports must include the SilentAirDrop file-rules format marker"
        )
        expect((document["version"] as? NSNumber)?.intValue == 1, "rule exports must use schema version 1")
        expect(document["defaultBehavior"] is String, "the exported default behavior must be a raw string")
        expect(
            document["categoryOverrides"] is [String: String],
            "exported category behaviors must use raw strings"
        )
        expect(
            document["extensionOverrides"] is [String: String],
            "exported extension behaviors must use raw strings"
        )
        expect(document["isEnabled"] == nil, "rule exports must not include the enabled setting")
        expect(document["launchAtLogin"] == nil, "rule exports must not include Launch at Login")
        expect(document["showMenuBarIcon"] == nil, "rule exports must not include menu bar settings")
    } else {
        expect(false, "exported rules must be a JSON object")
    }
} catch {
    expect(false, "valid file rules unexpectedly failed to export or import: \(error)")
}

expectRulesImportFailure(
    """
    {
      "format": "com.example.not-silent-airdrop",
      "version": 1,
      "defaultBehavior": "keepFinderClosed",
      "categoryOverrides": {},
      "extensionOverrides": {}
    }
    """,
    "an unrelated format marker must be rejected"
)

expectRulesImportFailure(
    """
    {
      "format": "com.gaptriko.SilentAirDrop.file-rules",
      "version": 2,
      "defaultBehavior": "keepFinderClosed",
      "categoryOverrides": {},
      "extensionOverrides": {}
    }
    """,
    "an unsupported future rules version must be rejected"
)

expectRulesImportFailure("{ definitely-not-json", "malformed rule JSON must be rejected")

expectRulesImportFailure(
    """
    {
      "format": "com.gaptriko.SilentAirDrop.file-rules",
      "version": 1,
      "defaultBehavior": "keepFinderClosed",
      "categoryOverrides": {
        "images": "allowFinder",
        "futureCategory": "futureBehavior"
      },
      "extensionOverrides": {}
    }
    """,
    "unknown categories must be rejected rather than silently discarded"
)

expectRulesImportFailure(
    """
    {
      "format": "com.gaptriko.SilentAirDrop.file-rules",
      "version": 1,
      "defaultBehavior": "futureBehavior",
      "categoryOverrides": {},
      "extensionOverrides": {}
    }
    """,
    "an unknown default behavior must be rejected"
)

expectRulesImportFailure(
    """
    {
      "format": "com.gaptriko.SilentAirDrop.file-rules",
      "version": 1,
      "defaultBehavior": "keepFinderClosed",
      "categoryOverrides": { "images": "futureBehavior" },
      "extensionOverrides": {}
    }
    """,
    "an unknown behavior for a known category must be rejected"
)

expectRulesImportFailure(
    """
    {
      "format": "com.gaptriko.SilentAirDrop.file-rules",
      "version": 1,
      "defaultBehavior": "keepFinderClosed",
      "categoryOverrides": {},
      "extensionOverrides": { "jpg": "futureBehavior" }
    }
    """,
    "an unknown extension behavior must be rejected"
)

expectRulesImportFailure(
    """
    {
      "format": "com.gaptriko.SilentAirDrop.file-rules",
      "version": 1,
      "defaultBehavior": "keepFinderClosed",
      "categoryOverrides": {},
      "extensionOverrides": { "bad/path": "allowFinder" }
    }
    """,
    "an invalid imported extension must be rejected rather than silently dropped"
)

expectRulesImportFailure(
    """
    {
      "format": "com.gaptriko.SilentAirDrop.file-rules",
      "version": 1,
      "defaultBehavior": "keepFinderClosed",
      "categoryOverrides": {},
      "extensionOverrides": { "foo bar": "allowFinder" }
    }
    """,
    "an imported extension containing whitespace must be rejected"
)

expectRulesImportFailure(
    """
    {
      "format": "com.gaptriko.SilentAirDrop.file-rules",
      "version": 1,
      "defaultBehavior": "keepFinderClosed",
      "categoryOverrides": {},
      "extensionOverrides": { "foo,bar": "allowFinder" }
    }
    """,
    "an imported extension containing a list separator must be rejected"
)

do {
    let data = Data(
        """
        {
          "format": "com.gaptriko.SilentAirDrop.file-rules",
          "version": 1,
          "defaultBehavior": "keepFinderClosed",
          "categoryOverrides": {},
          "extensionOverrides": {
            ".JPG": "allowFinder",
            "*.TAR.GZ": "keepFinderClosed"
          }
        }
        """.utf8
    )
    let importedPolicy = try FileBehaviorPolicy.importedRules(from: data)
    expect(
        importedPolicy.extensionOverrides == [
            "jpg": .allowFinder,
            "tar.gz": .keepFinderClosed
        ],
        "imported extensions must normalize case, leading dots, wildcards, and compound suffixes"
    )
} catch {
    expect(false, "valid normalized extensions unexpectedly failed to import: \(error)")
}

do {
    let data = Data(
        """
        {
          "format": "com.gaptriko.SilentAirDrop.file-rules",
          "version": 1,
          "defaultBehavior": "keepFinderClosed",
          "categoryOverrides": {},
          "extensionOverrides": {
            ".JPG": "allowFinder",
            "jpg": "allowFinder"
          }
        }
        """.utf8
    )
    let importedPolicy = try FileBehaviorPolicy.importedRules(from: data)
    expect(
        importedPolicy.extensionOverrides == ["jpg": .allowFinder],
        "same-behavior extension aliases must deduplicate after normalization"
    )
} catch {
    expect(false, "same-behavior extension aliases unexpectedly failed to import: \(error)")
}

expectRulesImportFailure(
    """
    {
      "format": "com.gaptriko.SilentAirDrop.file-rules",
      "version": 1,
      "defaultBehavior": "keepFinderClosed",
      "categoryOverrides": {},
      "extensionOverrides": {
        ".JPG": "allowFinder",
        "jpg": "keepFinderClosed"
      }
    }
    """,
    "conflicting extension aliases must be rejected after normalization"
)

do {
    let data = Data(
        """
        {
          "format": "com.gaptriko.SilentAirDrop.file-rules",
          "version": 1,
          "defaultBehavior": "allowFinder",
          "categoryOverrides": { "pdfs": "keepFinderClosed" },
          "extensionOverrides": { "HEIC": "allowFinder" },
          "exportedBy": "SilentAirDrop 1.1",
          "futureMetadata": { "note": "ignored" }
        }
        """.utf8
    )
    let importedPolicy = try FileBehaviorPolicy.importedRules(from: data)
    expect(
        importedPolicy == FileBehaviorPolicy(
            defaultBehavior: .allowFinder,
            categoryOverrides: [.pdfs: .keepFinderClosed],
            extensionOverrides: ["heic": .allowFinder]
        ),
        "unknown top-level metadata must not prevent current rules from importing"
    )
} catch {
    expect(false, "extra top-level metadata unexpectedly prevented import: \(error)")
}

do {
    let data = Data(
        """
        {
          "format": "com.gaptriko.SilentAirDrop.file-rules",
          "version": 1,
          "defaultBehavior": "allowFinder"
        }
        """.utf8
    )
    let importedPolicy = try FileBehaviorPolicy.importedRules(from: data)
    expect(
        importedPolicy == FileBehaviorPolicy(
            defaultBehavior: .allowFinder,
            categoryOverrides: [:],
            extensionOverrides: [:]
        ),
        "missing override maps must import as empty rules"
    )
} catch {
    expect(false, "a rules file with omitted empty overrides unexpectedly failed: \(error)")
}

do {
    let oversizedData = Data(repeating: 0x20, count: FileBehaviorPolicy.maximumRulesTransferSize + 1)
    _ = try FileBehaviorPolicy.importedRules(from: oversizedData)
    expect(false, "an oversized rules file must be rejected before decoding")
} catch let error as FileRulesTransferError {
    expect(error == .fileTooLarge, "an oversized rules file must report the file-too-large error")
} catch {
    expect(false, "an oversized rules file returned the wrong error: \(error)")
}

if failureCount > 0 {
    fputs("\(failureCount) of \(checkCount) checks failed.\n", stderr)
    exit(1)
}

print("All \(checkCount) file-rule checks passed.")
