import Foundation

public struct NameStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/deskman/names.json")
    }

    public private(set) var names: [String: String]
    private let url: URL

    public init(url: URL = NameStore.defaultURL) throws {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            names = try JSONDecoder().decode([String: String].self, from: data)
        } else {
            names = [:]
        }
    }

    public func uuid(forName name: String) -> String? {
        names.first { $0.value == name }?.key
    }

    public mutating func set(name: String, for uuid: String) throws {
        if name.isEmpty {
            names[uuid] = nil
        } else {
            if let owner = self.uuid(forName: name), owner != uuid {
                throw DeskmanError.duplicateName(name)
            }
            names[uuid] = name
        }
        try save()
    }

    public mutating func forget(name: String, liveUUIDs: Set<String>) throws {
        guard let uuid = uuid(forName: name) else { throw DeskmanError.nameNotFound(name) }
        if liveUUIDs.contains(uuid) { throw DeskmanError.hasLiveSpace(name) }
        names[uuid] = nil
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(names).write(to: url, options: .atomic)
    }
}
