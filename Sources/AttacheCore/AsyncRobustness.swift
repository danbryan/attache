import Foundation

/// Run `operation`, but if it hasn't finished within `seconds`, cancel it and
/// return `onTimeout()` instead. Used to keep a stalled conversation tool from
/// hanging the mic UI (INF-157).
public func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async -> T,
    onTimeout: @escaping @Sendable () -> T
) async -> T {
    await withTaskGroup(of: T?.self) { group -> T in
        group.addTask { Optional(await operation()) }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return nil
        }
        defer { group.cancelAll() }
        for await result in group {
            if let value = result { return value }   // operation finished first
            return onTimeout()                        // timeout fired first
        }
        return onTimeout()
    }
}

/// Retry an idempotent async operation up to `attempts` times with a short
/// backoff. For transient network failures on discovery GETs / TTS synthesis
/// (INF-157); never use for non-idempotent chat completions.
public func retrying<T>(
    attempts: Int = 2,
    backoff: Double = 0.4,
    operation: @escaping () async throws -> T
) async throws -> T {
    var lastError: Error?
    for attempt in 0..<max(1, attempts) {
        do {
            return try await operation()
        } catch {
            lastError = error
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: UInt64(max(0, backoff) * 1_000_000_000))
            }
        }
    }
    throw lastError ?? CancellationError()
}
