import Foundation

/// 本地数据目录约定：数据库与缓存统一放在 Application Support 下的同一目录。
enum AppStorageLocation {
    static let directoryName = "com.platojobs.codemagic"
    static let databaseFileName = "codemagic.sqlite"

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 数据库路径，调用前确保目录存在。
    static func databaseURL(fileManager: FileManager = .default) throws -> URL {
        let directory = defaultDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(databaseFileName)
    }
}
