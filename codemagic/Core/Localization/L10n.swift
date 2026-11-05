import Foundation

/// 界面文案统一入口：所有面向用户的字符串都从 `Localizable.strings` 读取。
///
/// key 命名规范：`<域>.<界面>.<语义>`，例如 `device.detail.exportCSV`、`smart.templates.empty`。
/// 英文与简体中文两套资源必须保持相同的 key 集合与相同的占位符数量（见 `LocalizationTests`）。
enum L10n {
    /// 测试可注入语言包；生产环境固定使用 main bundle。
    static var bundle: Bundle = .main

    static func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
    }

    /// 带参数模板：占位符统一写成 `%@`，参数已在调用点格式化为字符串。
    static func f(_ key: String, _ args: String...) -> String {
        var template = t(key)
        for arg in args {
            guard let range = template.range(of: "%@") else { break }
            template.replaceSubrange(range, with: arg)
        }
        return template
    }

    /// 变参数组版本，便于动态拼装。
    static func f(_ key: String, args: [String]) -> String {
        var template = t(key)
        for arg in args {
            guard let range = template.range(of: "%@") else { break }
            template.replaceSubrange(range, with: arg)
        }
        return template
    }
}
