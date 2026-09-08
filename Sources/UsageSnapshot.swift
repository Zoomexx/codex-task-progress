import Foundation

/// A single official quota window. The server reports consumption, while the
/// status bar displays the derived remaining percentage.
struct UsageWindow {
    let usedPercent: Double?
    let resetsAt: Date?
}

enum UsageSyncStatus: Equatable {
    case unavailable
    case syncing
    case current
    case delayed
    case stale
    case discrepancy

    var displayName: String {
        switch self {
        case .unavailable: return "不可用"
        case .syncing: return "同步中"
        case .current: return "已同步"
        case .delayed: return "更新延迟"
        case .stale: return "数据已过期"
        case .discrepancy: return "存在差额"
        }
    }
}

struct UsageSnapshot {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let modelContextWindow: Int?
    let sourceFile: String?
    let eventDate: Date?
    let receivedAt: Date?
    let status: UsageSyncStatus
    let statusDetail: String?
    let tokenDataAvailable: Bool

    static let empty = UsageSnapshot(
        fiveHour: UsageWindow(usedPercent: nil, resetsAt: nil),
        sevenDay: UsageWindow(usedPercent: nil, resetsAt: nil),
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningTokens: 0,
        totalTokens: 0,
        modelContextWindow: nil,
        sourceFile: nil,
        eventDate: nil,
        receivedAt: nil,
        status: .unavailable,
        statusDetail: nil,
        tokenDataAvailable: false
    )

    func replacing(
        status: UsageSyncStatus,
        statusDetail: String? = nil,
        receivedAt: Date? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            modelContextWindow: modelContextWindow,
            sourceFile: sourceFile,
            eventDate: eventDate,
            receivedAt: receivedAt ?? self.receivedAt,
            status: status,
            statusDetail: statusDetail,
            tokenDataAvailable: tokenDataAvailable
        )
    }
}
