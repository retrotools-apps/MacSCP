enum SleepingChildRegexFixture {
    static func demonstratesTheBannedShape() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(3))
            }
            try await group.waitForAll()
        }
    }

    /// The second shape the regex must catch, added in the fix round that
    /// turned `AsyncSignal.race(timeout:_:)`'s blind spot into a named
    /// exemption (2026-09-04): the sleep is not the child's first token —
    /// it sits one level inside a `do {}` — but it is still the first
    /// meaningful call the child makes, and still races real work in the
    /// same group. Never called from a test, for the same reason as
    /// `demonstratesTheBannedShape` above.
    static func demonstratesTheDoWrappedBannedShape() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    // unreachable in this fixture; `Task.sleep` throws only
                    // on cancellation, which nothing here triggers.
                }
            }
            try await group.waitForAll()
        }
    }
}
