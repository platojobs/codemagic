import Foundation

/// 「加入家庭」：输入 8 位邀请码，复用现有输入规范化与 404 / 429 文案。
final class HouseholdClaimViewModel {
    private let service: HouseholdService

    private(set) var input = ""
    private(set) var isClaiming = false
    private(set) var errorMessage: String?
    private(set) var claimedHousehold: Household?

    var onChange: (() -> Void)?

    init(service: HouseholdService) {
        self.service = service
    }

    var canClaim: Bool {
        !isClaiming && PairingCodeFormatter.isComplete(input)
    }

    var statusText: String {
        if let errorMessage { return errorMessage }
        if isClaiming { return L10n.t("household.join.progress") }
        let remaining = PairingCodeFormatter.codeLength - input.count
        if input.isEmpty {
            return L10n.t("household.join.hint")
        }
        return L10n.f("household.join.remaining", String(describing: max(0, remaining)))
    }

    @discardableResult
    func updateInput(_ raw: String) -> String {
        input = PairingCodeFormatter.normalize(raw)
        errorMessage = nil
        onChange?()
        return input
    }

    func claim() {
        guard canClaim else { return }
        isClaiming = true
        errorMessage = nil
        onChange?()
        service.claimInvitation(rawCode: input) { [weak self] result in
            guard let self else { return }
            self.isClaiming = false
            switch result {
            case .success(let household):
                self.claimedHousehold = household
                self.errorMessage = nil
                self.onChange?()
            case .failure(let error):
                self.errorMessage = error.claimUserMessage
                self.onChange?()
            }
        }
    }
}
