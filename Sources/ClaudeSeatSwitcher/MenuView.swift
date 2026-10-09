import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmUndo = false
    @State private var undoResult: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.accounts.isEmpty {
                EmptyState()
            } else {
                ForEach(model.accounts) { account in
                    AccountRow(account: account, suggested: model.suggested?.id == account.id && model.accounts.count > 1)
                }
            }

            if !model.statusLines.isEmpty {
                Divider()
                ForEach(model.statusLines) { line in
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.level == .error ? .red : line.level == .warning ? .orange : .secondary)
                }
            }

            if model.notificationsOff {
                Label("Notifications are off — limit alerts will not appear. Enable them in System Settings.",
                      systemImage: "bell.slash").font(.caption).foregroundStyle(.orange)
            }
            if let n = undoResult {
                Text("Removed \(n) shared conversation copies; sharing is off.").font(.caption).foregroundStyle(.secondary)
            }

            if let update = model.update {
                Divider()
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("Version \(update.version) is available").font(.caption)
                    Spacer()
                    Button("Download") { NSWorkspace.shared.open(update.page) }.controlSize(.small)
                }
            }

            Divider()
            HStack {
                Button("Add account…") {
                    openWindow(id: "add-account")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button {
                    Task { await model.refresh(force: true) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh now")
                Menu {
                    Toggle("Share Code-tab history across accounts", isOn: $model.shareHistory)
                    Button("Undo history sharing…") { confirmUndo = true }
                    Divider()
                    Toggle("Run status-line scripts", isOn: $model.runStatusLines)
                    Button("Open status-line scripts folder") { NSWorkspace.shared.open(Paths.statusLines) }
                    Toggle("Check for updates daily", isOn: $model.checkForUpdates)
                    Divider()
                    Button("Open accounts file") { NSWorkspace.shared.open(Paths.accountsFile) }
                    Button("About / source code") { NSWorkspace.shared.open(AppInfo.repository) }
                    Divider()
                    Button("Quit") { NSApp.terminate(nil) }
                } label: { Image(systemName: "gearshape") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
        }
        .padding(14)
        .frame(width: 370)
        .confirmationDialog("Undo history sharing?", isPresented: $confirmUndo) {
            Button("Remove copies and turn sharing off", role: .destructive) {
                Task { undoResult = await model.undoHistorySharing() }
            }
        } message: {
            Text("Conversation entries copied between accounts go to the Trash. Copies you have continued in are kept.")
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No accounts yet").font(.headline)
            Text("Add the account you use in your regular Claude window first, then one per extra seat.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    let suggested: Bool
    @State private var confirmRemove = false
    @State private var removeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(model.isOpen(account) ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
                Text(account.id).font(.system(.body, weight: .semibold))
                if !account.label.isEmpty {
                    Text(account.label).font(.caption).foregroundStyle(.secondary)
                }
                if account.role == .automation {
                    Text("automation").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                if suggested {
                    Text("most room").font(.caption2).foregroundStyle(.green)
                }
                Spacer()
                Button(model.isOpen(account) ? "Show" : "Open") { model.open(account) }
                    .controlSize(.small)
            }
            .contextMenu {
                Button(account.role == .automation ? "Mark as interactive" : "Mark as automation") {
                    var a = account
                    a.role = account.role == .automation ? .interactive : .automation
                    model.update(a)
                }
                Button("Remove…", role: .destructive) { confirmRemove = true }
            }
            .confirmationDialog("Remove \(account.id)?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { removeError = model.remove(account) }
            } message: {
                Text("Its separate Claude window profile goes to the Trash and its sign-in for usage data is deleted.")
            }
            if let removeError { Text(removeError).font(.caption).foregroundStyle(.red) }

            UsageStateView(state: model.usage[account.id] ?? .unknown)
        }
    }
}

struct UsageBars: View {
    let usage: Usage
    var body: some View {
        // Re-render every minute so countdowns stay current between usage fetches.
        TimelineView(.periodic(from: .now, by: 60)) { _ in bars }
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(usage.windows, id: \.label) { w in
                HStack(spacing: 6) {
                    Text(w.label).font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    Bar(fraction: min(max(w.percent, 0), 100) / 100,
                        color: w.percent >= AppModel.warnPercent ? .red : w.percent >= AppModel.busyPercent ? .orange : .accentColor)
                    Text("\(Int(w.percent.rounded()))%").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                    Text(Format.reset(w.resetsAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 74, alignment: .trailing)
                }
                .help(Format.resetSentence(w.label, w.resetsAt))
            }
        }
    }
}

/// A usage bar that keeps its colour even when the panel is not the key window.
private struct Bar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: max(geo.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 6)
    }
}

private struct UsageStateView: View {
    let state: UsageState
    var body: some View {
        switch state {
        case .unknown:
            Text("loading…").font(.caption).foregroundStyle(.secondary)
        case .loaded(let u):
            UsageBars(usage: u)
        case .failed(let message, let last, _):
            FailedView(message: message, last: last, rateLimited: state.isRateLimited)
        }
    }
}

private struct FailedView: View {
    let message: String
    let last: Usage?
    let rateLimited: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let last { UsageBars(usage: last).opacity(0.6) }
            if rateLimited {
                Text(last.map { "updated \(Format.time($0.fetchedAt)) — Anthropic asked to slow down, retrying later" }
                     ?? "Anthropic asked to slow down — retrying later")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
