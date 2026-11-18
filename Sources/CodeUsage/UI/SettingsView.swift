import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.refreshInterval) private var refreshInterval: Double = SettingsDefaults.refreshInterval
    @AppStorage(SettingsKey.autoRefreshTokens) private var autoRefreshTokens: Bool = SettingsDefaults.autoRefreshTokens
    @AppStorage(SettingsKey.showClaudeInMenuBar) private var showClaude: Bool = SettingsDefaults.showClaudeInMenuBar
    @AppStorage(SettingsKey.showCodexInMenuBar) private var showCodex: Bool = SettingsDefaults.showCodexInMenuBar
    @AppStorage(SettingsKey.claudeShowsRemaining) private var claudeShowsRemaining: Bool = SettingsDefaults.claudeShowsRemaining
    @AppStorage(SettingsKey.codexShowsRemaining) private var codexShowsRemaining: Bool = SettingsDefaults.codexShowsRemaining

    @State private var loginStatus: SMAppService.Status = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var credentials: CredentialStatus?

    private static let intervals: [Double] = [60, 120, 300, 600, 900]

    var body: some View {
        Form {
            Section("일반") {
                Picker("새로고침 주기", selection: $refreshInterval) {
                    ForEach(intervalOptions, id: \.self) { seconds in
                        Text(Self.intervalLabel(seconds)).tag(seconds)
                    }
                }

                Toggle("로그인 시 실행", isOn: launchAtLoginBinding)
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("시스템 설정 › 로그인 항목에서 허용해야 합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("로그인 항목 열기") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(UsageTheme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Toggle(isOn: $showClaude) {
                    Label("Claude", systemImage: UsageTheme.glyph(for: .claude))
                }
                Toggle(isOn: $showCodex) {
                    Label("Codex", systemImage: UsageTheme.glyph(for: .codex))
                }
            } header: {
                Text("메뉴 막대")
            } footer: {
                Text("현재 세션이 진행 중이면 세션을, 아니면 주간 한도를 표시합니다. 주간 한도는 숫자 옆 작은 w로 구분합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker(selection: $claudeShowsRemaining) {
                    Text("사용량").tag(false)
                    Text("남은 양").tag(true)
                } label: {
                    Label("Claude", systemImage: UsageTheme.glyph(for: .claude))
                }
                Picker(selection: $codexShowsRemaining) {
                    Text("사용량").tag(false)
                    Text("남은 양").tag(true)
                } label: {
                    Label("Codex", systemImage: UsageTheme.glyph(for: .codex))
                }
            } header: {
                Text("퍼센트 표시")
            } footer: {
                Text("남은 양으로 표시하면 100%에서 줄어듭니다. 메뉴 막대와 팝오버에 함께 적용됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("토큰") {
                Toggle(isOn: $autoRefreshTokens) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("토큰 자동 갱신")
                        Text("만료된 토큰을 갱신해 CLI 저장소(Claude Code 키체인 항목, ~/.codex/auth.json)에 다시 기록합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                CredentialRow(title: "Claude Code 키체인 항목",
                              detail: "Claude Code-credentials",
                              found: credentials?.claudeKeychain)
                CredentialRow(title: "Claude 자격 증명 파일",
                              detail: "~/.claude/.credentials.json",
                              found: credentials?.claudeFile)
                CredentialRow(title: "Codex 로그인 파일",
                              detail: credentials?.codexPath ?? CredentialStatus.codexAuthPath(abbreviated: true),
                              found: credentials?.codexFile)
            } header: {
                HStack {
                    Text("로그인 정보")
                    Spacer()
                    Button("다시 확인") { Task { await checkCredentials() } }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                }
            } footer: {
                Text("존재 여부만 확인하며 토큰 내용은 읽거나 표시하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .task { await checkCredentials() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    private var intervalOptions: [Double] {
        Self.intervals.contains(refreshInterval) ? Self.intervals : (Self.intervals + [refreshInterval]).sorted()
    }

    private static func intervalLabel(_ seconds: Double) -> String {
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(seconds / 60))분"
        }
        return "\(Int(seconds))초"
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
            set: { enable in setLaunchAtLogin(enable) }
        )
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        let service = SMAppService.mainApp
        do {
            if enable {
                try service.register()
            } else {
                try service.unregister()
            }
            loginError = nil
        } catch {
            loginError = "로그인 항목 \(enable ? "등록" : "해제") 실패: \(error.localizedDescription)"
        }
        loginStatus = service.status
    }

    private func checkCredentials() async {
        credentials = await CredentialStatus.check()
    }
}

private struct CredentialRow: View {
    let title: String
    let detail: String
    let found: Bool?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            switch found {
            case .none:
                ProgressView().controlSize(.small)
            case .some(true):
                Label("찾음", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            case .some(false):
                Label("없음", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }
}

/// Existence-only check of the CLI credential stores. Never reads secret values.
struct CredentialStatus: Sendable, Equatable {
    var claudeKeychain: Bool
    var claudeFile: Bool
    var codexFile: Bool
    var codexPath: String

    static func codexAuthPath(abbreviated: Bool) -> String {
        let home: String
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            home = (custom as NSString).expandingTildeInPath
        } else {
            home = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        }
        let path = (home as NSString).appendingPathComponent("auth.json")
        return abbreviated ? (path as NSString).abbreviatingWithTildeInPath : path
    }

    static func check() async -> CredentialStatus {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let claudeFile = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
            return CredentialStatus(
                claudeKeychain: keychainItemExists(service: "Claude Code-credentials"),
                claudeFile: fm.fileExists(atPath: claudeFile),
                codexFile: fm.fileExists(atPath: codexAuthPath(abbreviated: false)),
                codexPath: codexAuthPath(abbreviated: true)
            )
        }.value
    }

    /// Runs `security find-generic-password -s <service>` without `-w`: it only looks up the item's
    /// attributes (no secret, no keychain prompt). All output is discarded; only the exit status is used.
    private static func keychainItemExists(service: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
