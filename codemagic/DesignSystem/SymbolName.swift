import Foundation

/// 界面用到的 SF Symbols 名称集中定义。
/// 全部为 iOS 15 及更早可用的符号，不引入图片资源（AppIcon 除外）。
enum SymbolName {
    // MARK: - Tab

    static let homeTab = "house"
    static let homeTabSelected = "house.fill"
    static let smartTab = "sparkles"
    static let devicesTab = "dot.radiowaves.left.and.right"
    static let productsTab = "square.grid.2x2"
    static let productsTabSelected = "square.grid.2x2.fill"
    static let marketTab = "tag"
    static let marketTabSelected = "tag.fill"
    static let profileTab = "person.crop.circle"
    static let profileTabSelected = "person.crop.circle.fill"

    // MARK: - Bluetooth / Status

    static let bluetooth = "antenna.radiowaves.left.and.right"
    static let bluetoothPoweredOff = "antenna.radiowaves.left.and.right.slash"
    static let warning = "exclamationmark.triangle.fill"
    static let checkmark = "checkmark.circle.fill"
    static let signalEmpty = "wifi.slash"

    // MARK: - Actions

    static let add = "plus"
    static let delete = "trash"
    static let refresh = "arrow.clockwise"
    static let disclosure = "chevron.right"
    static let emptyList = "tray"
    static let settings = "gear"
    static let about = "info.circle"
    static let log = "list.bullet.rectangle"
    static let save = "square.and.arrow.down"
    static let edit = "pencil"

    // MARK: - Domain

    static let device = "dot.radiowaves.left.and.right"
    static let product = "shippingbox"
    static let firmware = "cpu"
    static let accessory = "cable.connector"
    static let compatibility = "checkmark.seal"
    static let rule = "bolt.fill"
    static let shield = "lock.shield"
}
