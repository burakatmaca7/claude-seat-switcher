import Foundation

/// Runs blocking work (Keychain via /usr/bin/security, file IO) off the Swift concurrency pool.
func offload<T>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .utility).async { cont.resume(returning: work()) }
    }
}

/// Fetches an account's usage, refreshing an app-owned sign-in shortly before it expires.
enum UsageService {
    static func fetch(_ account: Account, previous: Usage?) async -> UsageState {
        let service = Credentials.serviceName(cliConfigDir: account.cliConfigDir)
        guard var oauth = await offload({ Credentials.read(service: service) }) else {
            return .failed("not signed in — add the account again", last: previous)
        }
        // App-owned sign-ins are refreshed ahead of time. The default login is used until it really
        // expires; Claude Code refreshes it itself whenever it runs.
        let margin: TimeInterval = account.ownsCLIProfile ? 30 * 60 : 60
        if oauth.expiresAt.timeIntervalSinceNow < margin {
            guard account.ownsCLIProfile else {
                return .failed("sign-in expired — it refreshes the next time Claude Code runs", last: previous)
            }
            switch await TokenRefresher.shared.refresh(service: service, margin: margin) {
            case .success(let fresh): oauth = fresh
            case .failure(let message): return .failed(message, last: previous)
            }
        }
        do {
            return .loaded(try await Network.fetchUsage(accessToken: oauth.accessToken))
        } catch let failure as Network.Failure {
            return .failed(failure.description, last: previous, retryAfter: failure.retryAfter)
        } catch {
            return .failed("network error — will retry", last: previous)
        }
    }
}

/// Serializes token refreshes. A refresh rotates the refresh token on the server, so two refreshes
/// of the same sign-in at once (timer + manual refresh, or this app + Claude Code) could sign the
/// account out. Everything happens inside one actor call, re-reading the Keychain first.
actor TokenRefresher {
    static let shared = TokenRefresher()

    enum Outcome {
        case success(Credentials.OAuth)
        case failure(String)
    }

    /// Actors are reentrant across `await`, so concurrent calls for one sign-in share one task.
    private var inFlight: [String: Task<Outcome, Never>] = [:]

    func refresh(service: String, margin: TimeInterval) async -> Outcome {
        if let running = inFlight[service] { return await running.value }
        let task = Task { await self.perform(service: service, margin: margin) }
        inFlight[service] = task
        let outcome = await task.value
        inFlight[service] = nil
        return outcome
    }

    private func perform(service: String, margin: TimeInterval) async -> Outcome {
        // Someone (an earlier call, or Claude Code) may have refreshed it already.
        guard let current = await offload({ Credentials.read(service: service) }) else {
            return .failure("not signed in — add the account again")
        }
        if current.expiresAt.timeIntervalSinceNow >= margin { return .success(current) }

        // Checked BEFORE refreshing: a token that could not be saved afterwards would be lost.
        guard Credentials.canWriteBack(service: service, oauth: current) else {
            return .failure("this sign-in cannot be refreshed safely here — add the account again")
        }
        let token: Network.RefreshedToken
        do {
            token = try await Network.refresh(refreshToken: current.refreshToken)
        } catch let failure as Network.Failure {
            return .failure(failure.isSignedOut ? "signed out — add the account again" : failure.description)
        } catch {
            return .failure("network error — will retry")
        }
        // Claude Code may have refreshed meanwhile: never overwrite a newer sign-in.
        if let again = await offload({ Credentials.read(service: service) }),
           again.refreshToken != current.refreshToken {
            return .success(again)
        }
        var updated = current
        updated.accessToken = token.accessToken
        updated.refreshToken = token.refreshToken ?? current.refreshToken
        updated.expiresAt = Date().addingTimeInterval(token.expiresIn)
        if let r = token.refreshTokenExpiresIn { updated.refreshTokenExpiresAt = Date().addingTimeInterval(r) }
        let toWrite = updated
        guard await offload({ Credentials.write(service: service, oauth: toWrite) }) else {
            // The new token is still valid for this run; report so the user signs in again later.
            return .failure("could not save the refreshed sign-in — add the account again")
        }
        return .success(updated)
    }
}
