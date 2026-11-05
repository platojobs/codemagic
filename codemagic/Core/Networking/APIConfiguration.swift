import Foundation

/// 网络配置：BASE_URL 来自 xcconfig 注入的 Info.plist 键 `BASE_URL`，源码中不写死地址。
struct APIConfiguration: Equatable {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Debug 走本地 Go 服务，Release 走线上域名，见 `Config/Debug.xcconfig` 与 `Config/Release.xcconfig`。
    static func fromBundle(_ bundle: Bundle = .main) throws -> APIConfiguration {
        guard let rawValue = bundle.object(forInfoDictionaryKey: "BASE_URL") as? String else {
            throw AppError.configuration(L10n.t("config.missingBaseURL"))
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            throw AppError.configuration(L10n.f("config.invalidBaseURL", String(describing: rawValue)))
        }
        return APIConfiguration(baseURL: url)
    }

    var displayString: String { baseURL.absoluteString }
}
