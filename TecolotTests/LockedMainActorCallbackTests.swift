import Testing
@testable import Tecolot

@MainActor
struct LockedMainActorCallbackTests {
    @Test func repeatedReadsDoNotGrowTheCallbackStack() {
        var addresses: [UInt] = []
        let callback = LockedMainActorCallback<Int>()
        callback.replace { _ in
            var marker = 0
            let address = withUnsafePointer(to: &marker) {
                UInt(bitPattern: $0)
            }
            addresses.append(address)
        }

        for value in 0..<1_000 {
            callback.current?(value)
        }

        let first = addresses.first ?? 0
        let last = addresses.last ?? 0
        let stackGrowth = first > last ? first - last : last - first

        #expect(addresses.count == 1_000)
        #expect(
            stackGrowth < 4_096,
            "callback stack grew by \(stackGrowth) bytes")
    }
}
