import Foundation

/// 有界指数退避：30 秒起，逐次翻倍，封顶 1 小时；达到自动重试上限后只保留手动入口。
enum FeedbackRetryPolicy {
    static let baseDelay: TimeInterval = 30
    static let maxDelay: TimeInterval = 3600

    static func delay(afterAttempts attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        let exponent = min(attempts - 1, 10)
        return min(baseDelay * pow(2, Double(exponent)), maxDelay)
    }
}

/// 反馈发送协调器：本地队列 → 幂等提交 → 状态回写。
/// 状态机只有「收到 2xx 且拿到 feedbackId」才会进入 `sent`。
final class FeedbackCoordinator {
    let store: FeedbackStore
    private let client: FeedbackServicing
    private let contextProvider: () -> FeedbackClientContext
    private let diagnosticsProvider: () -> String?
    private let now: () -> Date
    private var isDraining = false

    /// 队列变化通知，界面据此刷新角标与列表。
    var onChange: (() -> Void)?

    init(
        store: FeedbackStore,
        client: FeedbackServicing,
        contextProvider: @escaping () -> FeedbackClientContext = { FeedbackClientContext.current() },
        diagnosticsProvider: @escaping () -> String? = { nil },
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.client = client
        self.contextProvider = contextProvider
        self.diagnosticsProvider = diagnosticsProvider
        self.now = now
        try? store.recoverInterruptedSends()
    }

    /// 新反馈：先落库（默认 pending），随后立即尝试发送。
    func enqueue(
        category: FeedbackCategory,
        message: String,
        contact: String,
        completion: ((Result<FeedbackDraft, FeedbackSendFailure>) -> Void)? = nil
    ) {
        do {
            let draft = try store.insert(
                category: category,
                message: message,
                contact: contact,
                at: now()
            )
            onChange?()
            send(id: draft.id, completion: completion)
        } catch {
            completion?(.failure(FeedbackSendFailure(
                message: L10n.t("feedback.error.localStore"),
                isRateLimited: false,
                retryAfter: nil,
                isRetryable: true,
                isConflict: false,
                apiCode: nil
            )))
        }
    }

    /// 前台手动重试或自动重试共用同一条发送路径，幂等键始终是草稿本地 ID。
    func send(
        id: String,
        completion: ((Result<FeedbackDraft, FeedbackSendFailure>) -> Void)? = nil
    ) {
        guard let draft = try? store.fetch(id: id) else {
            completion?(.failure(FeedbackSendFailure(
                message: L10n.t("feedback.error.localStore"),
                isRateLimited: false,
                retryAfter: nil,
                isRetryable: true,
                isConflict: false,
                apiCode: nil
            )))
            return
        }
        if draft.isSent || draft.status == .sending {
            completion?(.success(draft))
            return
        }
        guard let sending = try? store.markSending(id: id, at: now()) else {
            completion?(.failure(FeedbackSendFailure(
                message: L10n.t("feedback.error.localStore"),
                isRateLimited: false,
                retryAfter: nil,
                isRetryable: true,
                isConflict: false,
                apiCode: nil
            )))
            return
        }
        onChange?()

        client.submit(
            draft: sending,
            context: contextProvider(),
            diagnostics: diagnosticsProvider()
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let receipt):
                let trimmed = receipt.feedbackID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.finish(
                        id: id,
                        failure: FeedbackSendFailure(
                            message: L10n.t("feedback.error.missingReceipt"),
                            isRateLimited: false,
                            retryAfter: nil,
                            isRetryable: true,
                            isConflict: false,
                            apiCode: nil
                        ),
                        attempts: sending.attempts,
                        completion: completion
                    )
                    return
                }
                let updated = try? self.store.markSent(id: id, remoteID: trimmed, at: self.now())
                self.onChange?()
                completion?(.success(updated ?? sending))
            case .failure(let failure):
                self.finish(
                    id: id,
                    failure: failure,
                    attempts: sending.attempts,
                    completion: completion
                )
            }
        }
    }

    /// 回到前台 / 进入反馈页时调用：只发到期的候选，失败后按退避推迟，不无限重试。
    func retryEligible(limit: Int = 3, completion: (() -> Void)? = nil) {
        guard !isDraining else {
            completion?()
            return
        }
        try? store.recoverInterruptedSends()
        guard let candidates = try? store.fetchAutoRetryCandidates(limit: limit, at: now()),
              !candidates.isEmpty
        else {
            completion?()
            return
        }
        isDraining = true
        drain(ids: candidates.map(\.id), completion: completion)
    }

    func pendingCount() -> Int {
        (try? store.pendingCount()) ?? 0
    }

    /// 「我的反馈」远端列表，游标分页由界面控制。
    func fetchMine(
        cursor: String?,
        limit: Int,
        completion: @escaping (Result<FeedbackPage, AppError>) -> Void
    ) {
        client.fetchMine(cursor: cursor, limit: limit, completion: completion)
    }

    /// 单条反馈详情（含服务端状态说明）。
    func fetchDetail(
        id: String,
        completion: @escaping (Result<FeedbackDetailItem, AppError>) -> Void
    ) {
        client.fetchDetail(id: id, completion: completion)
    }

    /// 关闭本人反馈；已关闭再改会得到 409 对应的明确文案。
    func close(
        id: String,
        completion: @escaping (Result<FeedbackDetailItem, FeedbackSendFailure>) -> Void
    ) {
        client.close(id: id, completion: completion)
    }

    // MARK: - Private

    private func drain(ids: [String], completion: (() -> Void)?) {
        guard let id = ids.first else {
            isDraining = false
            completion?()
            return
        }
        send(id: id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.drain(ids: Array(ids.dropFirst()), completion: completion)
            case .failure(let failure):
                // 限流或终态失败（如 409 / 401）时停止本轮批量重试，避免放大服务端压力。
                if failure.isRateLimited || !failure.isRetryable {
                    self.isDraining = false
                    completion?()
                } else {
                    self.drain(ids: Array(ids.dropFirst()), completion: completion)
                }
            }
        }
    }

    private func finish(
        id: String,
        failure: FeedbackSendFailure,
        attempts: Int,
        completion: ((Result<FeedbackDraft, FeedbackSendFailure>) -> Void)?
    ) {
        let retryAt: Date?
        if failure.isRateLimited {
            retryAt = now().addingTimeInterval(failure.retryAfter ?? 60)
        } else if failure.isRetryable && !failure.isConflict && attempts < FeedbackStore.maxAutoAttempts {
            retryAt = now().addingTimeInterval(FeedbackRetryPolicy.delay(afterAttempts: attempts))
        } else {
            retryAt = nil
        }
        _ = try? store.markFailed(
            id: id,
            error: failure.message,
            nextRetryAt: retryAt,
            at: now()
        )
        onChange?()
        completion?(.failure(failure))
    }
}
