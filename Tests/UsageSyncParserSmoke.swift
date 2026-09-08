import Foundation

@main
struct UsageSyncParserSmoke {
    static func main() {
        let response: [String: Any] = [
            "rateLimits": [
                "primary": [
                    "usedPercent": 21,
                    "windowDurationMins": 300,
                    "resetsAt": 1_788_170_000
                ],
                "secondary": [
                    "usedPercent": 6,
                    "windowDurationMins": 10_080,
                    "resetsAt": 1_788_776_000
                ]
            ]
        ]

        guard let parsed = OfficialUsageClient.parseRateLimits(response) else {
            fatalError("official rate-limit fixture did not parse")
        }
        precondition(parsed.fiveHour.usedPercent == 21)
        precondition(parsed.sevenDay.usedPercent == 6)
        precondition(parsed.fiveHour.resetsAt != nil)
        precondition(parsed.sevenDay.resetsAt != nil)

        // Window mapping must use duration, not array/role order.
        let swapped: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 8, "windowDurationMins": 10_080],
                "secondary": ["usedPercent": 37, "windowDurationMins": 300]
            ]
        ]
        guard let swappedParsed = OfficialUsageClient.parseRateLimits(swapped) else {
            fatalError("swapped official rate-limit fixture did not parse")
        }
        precondition(swappedParsed.fiveHour.usedPercent == 37)
        precondition(swappedParsed.sevenDay.usedPercent == 8)

        print("UsageSyncParserSmoke: PASS")
    }
}
