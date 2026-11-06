import Foundation

/// `GET /scenes`、`POST /scenes`、`PUT /scenes/{id}` 与 `change_log` 中 `scene` 实体的完整结构。
struct RemoteScene: Equatable {
    let id: String
    let name: String
    let enabled: Bool
    let cooldownSeconds: Int
    let trigger: SceneTrigger?
    let actions: [SceneAction]
    let version: Int64
    let deviceMissing: Bool
    let createdAt: Date?
    let updatedAt: Date
    let deletedAt: Date?

    init(
        id: String,
        name: String,
        enabled: Bool,
        cooldownSeconds: Int,
        trigger: SceneTrigger?,
        actions: [SceneAction],
        version: Int64,
        deviceMissing: Bool,
        createdAt: Date?,
        updatedAt: Date,
        deletedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.cooldownSeconds = cooldownSeconds
        self.trigger = trigger
        self.actions = actions
        self.version = version
        self.deviceMissing = deviceMissing
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

extension RemoteScene: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, cooldownSeconds, trigger, actions, version
        case deviceMissing, createdAt, updatedAt, deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        cooldownSeconds = (try? container.decodeIfPresent(Int.self, forKey: .cooldownSeconds)) ?? 300
        trigger = try? container.decodeIfPresent(SceneTrigger.self, forKey: .trigger)
        actions = (try? container.decodeIfPresent([SceneAction].self, forKey: .actions)) ?? []
        version = (try? container.decodeIfPresent(Int64.self, forKey: .version)) ?? 0
        deviceMissing = (try? container.decodeIfPresent(Bool.self, forKey: .deviceMissing)) ?? false
        createdAt = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .createdAt)) ?? ""
        )
        updatedAt = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
        ) ?? Date(timeIntervalSince1970: 0)
        deletedAt = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .deletedAt)) ?? ""
        )
    }
}

/// `POST /scenes` 请求体。
struct SceneCreateInput: Encodable {
    let name: String
    let enabled: Bool
    let cooldownSeconds: Int
    let trigger: SceneTrigger
    let actions: [SceneAction]
}

/// `PUT /scenes/{id}` 中单个字段的 LWW 包装。
struct SceneFieldPatch<Value: Encodable>: Encodable {
    let value: Value
    let updatedAt: String
}

/// `PUT /scenes/{id}` 请求体：只出现的字段参与比较，其余保持不变。
struct ScenePatchInput: Encodable {
    var name: SceneFieldPatch<String>?
    var enabled: SceneFieldPatch<Bool>?
    var cooldownSeconds: SceneFieldPatch<Int>?
    var trigger: SceneFieldPatch<SceneTrigger>?
    var actions: SceneFieldPatch<[SceneAction]>?

    init() {}

    /// 用本地脏字段构造补丁；`lastSyncedAt` 为空表示从未同步，全部字段都算脏。
    init(scene: Scene) {
        for field in scene.dirtyFields {
            switch field {
            case .name:
                name = SceneFieldPatch(value: scene.name, updatedAt: SyncDateCodec.string(from: scene.field(.name).date))
            case .enabled:
                enabled = SceneFieldPatch(value: scene.enabled, updatedAt: SyncDateCodec.string(from: scene.field(.enabled).date))
            case .cooldownSeconds:
                cooldownSeconds = SceneFieldPatch(
                    value: scene.cooldownSeconds,
                    updatedAt: SyncDateCodec.string(from: scene.field(.cooldownSeconds).date)
                )
            case .trigger:
                trigger = SceneFieldPatch(value: scene.trigger, updatedAt: SyncDateCodec.string(from: scene.field(.trigger).date))
            case .actions:
                actions = SceneFieldPatch(value: scene.actions, updatedAt: SyncDateCodec.string(from: scene.field(.actions).date))
            }
        }
    }

    var isEmpty: Bool {
        name == nil && enabled == nil && cooldownSeconds == nil && trigger == nil && actions == nil
    }
}
