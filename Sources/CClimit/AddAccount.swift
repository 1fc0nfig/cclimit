import AppKit
import CClimitCore
import SwiftUI

/// Opens the Add Account sheet, with a name to start from ("Add Back…" fills one in).
struct AddAccountRequest: Identifiable {
    let id = UUID()
    var name: String = ""
}

/// The login the Add Account sheet waits for. AppState owns it, so polling outlives a
/// closed Settings window.
struct PendingLogin: Equatable {
    enum Phase: Equatable {
        case waiting
        case added(label: String)
        case alreadyTracked(name: String)
        case timedOut
        case failed(String)
    }

    let name: String
    let folder: URL
    var phase: Phase
    /// Set when the alias could not be written. The login still goes ahead.
    var aliasNote: String?
}

enum AddAccountLauncher {
    /// The user's login shell from the user database. A GUI app's `$SHELL` is not reliable.
    static var userShell: AccountSetup.Shell {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return AccountSetup.Shell(shellPath: String(cString: shell))
        }
        return AccountSetup.Shell(shellPath: ProcessInfo.processInfo.environment["SHELL"])
    }

    static func createFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Writes the login script to a `.command` file and opens it with Terminal. Terminal
    /// runs a `.command` file on open, so no AppleScript and no Automation permission.
    static func openLoginInTerminal(folder: URL, slug: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cclimit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("add-account-\(slug).command")
        try Data(AccountSetup.loginScript(folder: folder).utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration)
    }
}

/// Settings > Accounts > "Add Account…": a name, the folder it makes, and an optional shell
/// command. Then it waits for the login to show up in the Keychain.
struct AddAccountSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var addAlias = false
    @State private var starting = false

    private let shell = AddAccountLauncher.userShell
    private let home = FileManager.default.homeDirectoryForCurrentUser

    init(prefill: String = "") {
        _name = State(initialValue: prefill)
    }

    private var validation: AccountSetup.Validation {
        AccountSetup.validate(
            name: name, home: home,
            takenNames: state.monitors.map { state.name(for: $0.account) },
            loginIDs: Set(state.monitors.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let pending = state.pendingLogin {
                progress(pending)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Name form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add an Account")
                    .font(.headline)
                Text("cclimit makes a folder for the account and opens Terminal. Log in there, and the account shows up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $name, prompt: Text("Work"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(start)
                validationLine
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: $addAlias) {
                    Text("Add a \(Text(commandName).font(.system(.body, design: .monospaced))) command to my shell")
                }
                .toggleStyle(.checkbox)
                .disabled(!validation.isValid)
                Text("Adds an alias to \(shell.rcDisplayPath). Use it to start Claude Code with this account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    state.cancelPendingLogin()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Continue", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validation.isValid || starting)
            }
        }
    }

    private var commandName: String {
        if case .valid(let slug, _) = validation { return AccountSetup.commandName(slug: slug) }
        return "claude-name"
    }

    @ViewBuilder
    private var validationLine: some View {
        switch validation {
        case .valid(_, let folder):
            let exists = FileManager.default.fileExists(atPath: folder.path)
            Text("\(exists ? "Uses" : "Creates") \(Self.tilde(folder))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        case .empty:
            Text("Enter a name, for example Work.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .noLettersOrDigits:
            error("Use at least one letter or digit.")
        case .duplicateName:
            error("Another account already uses this name.")
        case .folderHasLogin(let folder):
            error("\(Self.tilde(folder)) already holds a login. Pick another name.")
        }
    }

    private func error(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func start() {
        guard case .valid(let slug, let folder) = validation, !starting else { return }
        starting = true
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await state.beginAddAccount(
                name: trimmed, slug: slug, folder: folder, aliasShell: addAlias ? shell : nil)
            starting = false
        }
    }

    // MARK: - Waiting and result

    @ViewBuilder
    private func progress(_ pending: PendingLogin) -> some View {
        switch pending.phase {
        case .waiting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to log in…")
                    .font(.headline)
            }
            Text("Finish the login in Terminal and your browser. This closes when cclimit sees the login in \(Self.tilde(pending.folder)). Closed Terminal by mistake? Cancel and start again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            aliasNote(pending)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    state.cancelPendingLogin()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        case .added(let label):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text("Added \(label)")
                    .font(.headline)
            }
            // The close timer sits on a view that always renders. On the alias note it
            // never ran when there was no note, and the sheet stayed up for good.
            .task {
                try? await Task.sleep(for: .seconds(pending.aliasNote == nil ? 1.5 : 4))
                state.clearPendingLogin()
                dismiss()
            }
            aliasNote(pending)
            HStack {
                Spacer()
                Button("Done") {
                    state.clearPendingLogin()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        case .alreadyTracked(let existing):
            result(
                title: "This account is already here",
                detail: "cclimit tracks it as \(existing). Log in with a different account to add one.")
        case .timedOut:
            result(
                title: "No login showed up",
                detail: "cclimit waited ten minutes. Try again when you are ready.",
                retry: true)
        case .failed(let message):
            result(title: "cclimit could not start the login", detail: message, retry: true)
        }
    }

    @ViewBuilder
    private func aliasNote(_ pending: PendingLogin) -> some View {
        if let note = pending.aliasNote {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func result(title: String, detail: String, retry: Bool = false) -> some View {
        Text(title)
            .font(.headline)
        Text(detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            if retry {
                Button("Try Again") { state.clearPendingLogin() }
            }
            Button("Close") {
                state.clearPendingLogin()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    static func tilde(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
