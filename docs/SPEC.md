# CodeUsage — spec

Personal macOS menu bar app (single user, no distribution). Shows Claude **and** Codex plan usage at once,
reusing the logins the CLIs already have on this Mac. Look & feel follows the "Usage for Claude" popover
(see the reference description at the bottom).

Build: Swift Package (`Package.swift`, swift-tools 6.0, Swift 5 language mode, macOS 14+), plain AppKit + SwiftUI,
no third-party dependencies. `scripts/build.sh` assembles `build/CodeUsage.app` (LSUIElement, ad-hoc signed).

Shared contract: `Sources/CodeUsage/Core/Models.swift` and `Core/AppSettings.swift` (already written — do not change
their public shape; adding helpers in your own files is fine).

## Security rules (all code)
- Never log, print, persist (outside the CLI's own store), or display access/refresh tokens.
- `CODEUSAGE_DEBUG=1` may print raw usage-response JSON to stderr (usage JSON has no secrets); never headers.
- Network calls only to the official hosts listed below.

## File ownership
| Owner | Files |
|---|---|
| Claude provider | `Providers/ClaudeProvider.swift`, `Providers/ClaudeCredentials.swift`, `Core/HTTP.swift` (shared helpers: JSON GET/POST, flexible number/date decoding, ISO8601 parsing, JWT payload decoding) |
| Codex provider | `Providers/CodexProvider.swift`, `Providers/CodexCredentials.swift` (may use `Core/HTTP.swift` helpers; if not there yet, write private helpers in your own files) |
| Store & infra | `Core/UsageStore.swift`, `Core/HistoryStore.swift`, `Core/Formatting.swift`, `Core/DebugCommands.swift`, `scripts/build.sh`, `README.md` |
| UI & app | `App/main.swift`, `App/AppDelegate.swift`, `App/StatusItemController.swift`, `UI/MenuBarLabel.swift`, `UI/PopoverView.swift`, `UI/UsageRowView.swift`, `UI/SettingsView.swift`, `UI/HistoryView.swift`, `UI/WindowManager.swift` |

## Claude provider
Credentials (written by Claude Code 2.1.x):
- macOS Keychain generic password, service `Claude Code-credentials` (account = the macOS user name). Read with
  `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` via `Process` (no shell). Using the
  `security` tool avoids a keychain ACL prompt for our ad-hoc signed app (Claude Code itself uses it).
- Fallback file `~/.claude/.credentials.json` (same JSON).
- JSON: `{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt" (epoch ms), "refreshTokenExpiresAt", "scopes": [..], "subscriptionType" ("team"/"max"/"pro"...), "rateLimitTier", ...}}` — preserve unknown keys on write-back.
- Missing → `ProviderError.notLoggedIn("Claude Code 로그인이 필요합니다. 터미널에서 claude 실행 후 /login")`.

Token refresh (only when `UserDefaults[autoRefreshTokens]` is true; otherwise `.tokenExpired("Claude Code 토큰이 만료되었습니다. 터미널에서 claude 를 한 번 실행하세요")`):
- Trigger: `expiresAt <= now + 60s`, or a 401 that persists after re-reading the keychain once (Claude Code may have refreshed meanwhile).
- `POST https://platform.claude.com/v1/oauth/token`, JSON body
  `{"grant_type":"refresh_token","refresh_token":R,"client_id":"9d1c250a-e61b-44d9-88ed-5944d1962f5e","scope":"<scopes joined by space>"}`
  → `{"access_token","refresh_token"? (keep old if absent),"expires_in" (s),"refresh_token_expires_in"?,"scope"?}`.
- Write back into the same keychain item, keeping every other key: run `/usr/bin/security -i` and feed on **stdin**
  `add-generic-password -U -a <account> -s "Claude Code-credentials" -X <hex of UTF-8 JSON>\n` so the secret never
  appears in argv. Account: parse `"acct"<blob>="..."` from `security find-generic-password -s "Claude Code-credentials"` (no -w), fallback `NSUserName()`.
  If credentials came from the fallback file, write the file back atomically (0600) instead.
- Serialize refreshes (actor) so two fetches never refresh concurrently.

Usage: `GET https://api.anthropic.com/api/oauth/usage` with headers
`Authorization: Bearer <access>`, `anthropic-beta: oauth-2025-04-20`, `Accept: application/json`, `User-Agent: CodeUsage/1.0`.
Response (all fields optional/nullable — decode leniently, ignore unknown keys):
```json
{
  "five_hour":  {"utilization": 9.0, "resets_at": "2026-11-18T07:40:00.123+00:00"},
  "seven_day":  {"utilization": 2.0, "resets_at": "..."},
  "seven_day_opus": {...} | null, "seven_day_sonnet": {...} | null, "seven_day_oauth_apps": ... ,
  "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null, "currency": "USD"},
  "limits": [ {"kind": "session"|"weekly_all"|"weekly_scoped"|..., "group": "session"|"weekly", "percent": 9.0,
               "resets_at": "ISO" | null, "severity": "normal"|"warning"|"critical", "is_active": true,
               "scope": {"model": {"display_name": "Opus"}?, "surface": {"display_name": "..."}?}?, "label"?: "..."} ]
}
```
Mapping:
- Prefer `limits[]` when present and non-empty: `kind=="session"` → `session` (window 18_000 s); `kind=="weekly_all"` → `weekly` (604_800 s);
  other rows (`weekly_scoped` etc.) → `extraWindows` (id = kind + scope name, label = "<scope display_name> 주간" or label/kind; window by group: session→18_000 else 604_800). `percent` is 0–100.
- Else fall back to `five_hour` / `seven_day` (`utilization` is 0–100) and `seven_day_opus` / `seven_day_sonnet` → extras ("Opus 주간", "Sonnet 주간") when non-null.
- `resets_at` null → `resetsAt = nil` (no running window; keep the window with its percent so the UI can say "활성 세션 없음").
- ISO8601 parsing must accept fractional seconds and `+00:00` offsets.

Profile (cache ~1 h inside the provider): `GET https://api.anthropic.com/api/oauth/profile`, same headers →
`{"account": {"display_name"?, "full_name"?, "email"?}, "organization": {"name"?, "organization_type"? ("claude_team","claude_max","claude_pro","claude_enterprise",...)}}`.
`AccountInfo.name` = display_name ?? full_name; plan = from organization_type (strip `claude_`, capitalize: Team/Max/Pro/Enterprise), fallback credentials `subscriptionType` capitalized. A profile failure must not fail the usage fetch.

## Codex provider
Credentials: `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`):
`{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token","access_token","refresh_token","account_id"},"last_refresh":"2026-11-16T04:29:26.847400Z"}`.
- Missing file / no tokens / auth_mode not chatgpt → `.notLoggedIn("Codex에 ChatGPT 계정으로 로그인하세요 (codex login)")`.
- JWT payloads (base64url, no verification): `id_token` → `email`, `name`, and claim object `"https://api.openai.com/auth"` → `chatgpt_plan_type`, `chatgpt_account_id`. `access_token` → `exp`.

Refresh (same `autoRefreshTokens` gate; if off → `.tokenExpired("Codex 토큰이 만료되었습니다. codex 를 한 번 실행하세요")`):
- Trigger: access `exp <= now + 60s`, or a 401 that persists after re-reading auth.json once.
- Re-read the file right before refreshing (the CLI may have refreshed). `POST https://auth.openai.com/oauth/token`, JSON
  `{"client_id":"app_EMoamEEZ73f0CkXaXp7hrann","grant_type":"refresh_token","refresh_token":R,"scope":"openid profile email"}`
  → `{"id_token"?,"access_token"?,"refresh_token"?}` (keep old values for absent keys).
- Write back atomically (temp file in same dir + rename), preserve unknown keys, set `last_refresh` to now (ISO8601, fractional seconds, `Z`), keep mode 0600. Serialize refreshes (actor).

Usage: `GET https://chatgpt.com/backend-api/wham/usage` with `Authorization: Bearer <access>`, `ChatGPT-Account-Id: <account_id>`,
`Accept: application/json`, `User-Agent: CodeUsage/1.0`. Response (lenient; numbers may be int or double):
```json
{"plan_type":"prolite",
 "rate_limit":{"allowed":true,"limit_reached":false,
   "primary_window":{"used_percent":77,"limit_window_seconds":604800,"reset_after_seconds":123456,"reset_at":1795408223},
   "secondary_window":null},
 "additional_rate_limits":[{"limit_name":"...","metered_feature":"...","rate_limit":{"primary_window":{...},"secondary_window":{...}}}] | null,
 "credits":{"has_credits":false,"unlimited":false,"balance":"0"}}
```
Mapping: classify each of primary/secondary by `limit_window_seconds` (<= 86_400 → `session`, else `weekly`). **Do not assume primary = 5h**:
this account's current plan has only a weekly primary window and no secondary. `resetsAt` = `reset_at` (epoch s) or now + `reset_after_seconds`.
additional_rate_limits windows → `extraWindows` (label from limit_name/metered_feature). Plan display from `plan_type`:
plus→Plus, pro→Pro, prolite→Pro Lite, team→Team, business→Business, enterprise→Enterprise, edu→Edu, free→Free, else capitalized; fallback to the JWT plan claim.
`AccountInfo.name` = JWT name ?? email.

## Store & infra
```swift
@MainActor final class UsageStore: ObservableObject {
    static let shared: UsageStore
    @Published private(set) var snapshots: [ProviderID: ProviderSnapshot]   // latest successful snapshot (kept when a later fetch fails)
    @Published private(set) var errors: [ProviderID: ProviderError]         // latest error; cleared on success
    @Published private(set) var loading: Set<ProviderID>
    @Published private(set) var lastRefresh: Date?
    init(providers: [UsageProvider] = [ClaudeProvider(), CodexProvider()])
    func start()                                   // initial refresh + polling loop (interval re-read from UserDefaults each cycle, min 30 s); refresh on NSWorkspace.didWakeNotification
    func refresh() async                           // both providers concurrently; ignore if already refreshing
    func refreshIfStale(maxAge: TimeInterval)      // used when the popover opens (maxAge 30)
    func burnRatePerHour(for: ProviderID, session: Bool) -> Double?   // %/hour, see below
    func projectedExhaustion(for: ProviderID, session: Bool) -> Date? // when usage hits 100% at current rate, only if before the window resets
    func history(for: ProviderID) -> [UsageSample]
    func summaryText() -> String                   // plain-text summary for the copy button
}
```
- `ClaudeProvider()` / `CodexProvider()` have zero-argument initializers (they read `autoRefreshTokens` from `UserDefaults.standard` at fetch time).
- History: `HistoryStore` persists `[ProviderID: [UsageSample]]` to `~/Library/Application Support/CodeUsage/history.json`, keeps 8 days, appends a sample per successful fetch (skip if < 60 s since previous and values unchanged).
- Burn rate (session): among samples within the same window (resetsAt within ±120 s of the current one) in the last 60 min, if span ≥ 10 min → (last − first) / hours (clamp ≥ 0). Otherwise average since window start: usedPercent / elapsed hours, if elapsed ≥ 5 min. Weekly: same logic but over the last 24 h, still expressed per hour. nil when unknown.
- `Formatting.swift`: `Fmt.percent(Double) -> String` ("9%", "<1%" for 0<x<1), `Fmt.resetText(resetsAt:now:) -> String` = `"Resets in 2 hr 7 min (수, 16:40)"`; ≥ 24 h → `"Resets in 3 days 4 hr (화, 22:00)"`; < 1 min → `"Resets in <1 min"`; weekday in Korean (`ko_KR`, "E"), 24 h clock. `Fmt.rate(Double) -> String` = `"8.0%/hr"`. `Fmt.relative(Date, now:) -> String` = "지금" (< 60 s), "3분 전", "2시간 전".
- `DebugCommands.swift`: `enum DebugCommands { static func runIfRequested() -> Bool }` handling
  `--dump` (fetch both providers once, print each snapshot as pretty JSON + any error to stdout, exit code 0) and
  `--render-preview <dir>` (render `PopoverView` and `MenuBarLabel` with **built-in sample data** — no network — to PNGs at 2x via `ImageRenderer`, light and dark variants). Uses `UsageStore.preview()` — a static factory returning a store filled with sample snapshots (Claude: Team, session 9% resetting in 2h7m, weekly 2% resetting in 7h27m; Codex: Pro Lite, no session window, weekly 77% resetting in 4 days). Add `init(previewSnapshots:)` or similar to support it.
- `scripts/build.sh [--install] [--run]`: `swift build -c release`, assemble `build/CodeUsage.app` (Info.plist: CFBundleIdentifier `com.jhoh.CodeUsage`, CFBundleName `CodeUsage`, CFBundleDisplayName `Code Usage`, CFBundleExecutable `CodeUsage`, APPL, version 1.0, LSMinimumSystemVersion 14.0, LSUIElement true), `codesign --force --sign -`; `--install` copies to `~/Applications/CodeUsage.app` (replacing, after quitting a running copy); `--run` opens the installed (or built) app.

## UI & app
- `main.swift`: `SettingsDefaults.register()`; `if DebugCommands.runIfRequested() { exit(0) }`; NSApplication with `.accessory` policy, `AppDelegate`.
- Status item (`NSStatusItem.variableLength`): button image = `MenuBarLabel` rendered with `ImageRenderer` (scale = screen backing scale), `isTemplate = true`, re-rendered when the store changes and every 30 s (sessions can expire). Left click toggles an `NSPopover` (`.transient`, SwiftUI `PopoverView` via `NSHostingController`, calls `refreshIfStale(30)` on open). Right click → menu: 새로고침 / 설정… / 종료.
- **Menu bar label** (user requirement): for each provider enabled in settings (Claude, then Codex) show one value: the **current session if a session is live, otherwise the weekly limit** (`ProviderSnapshot.menuBarWindow()`). Each item = small provider glyph (Claude: SF Symbol `asterisk`; Codex: `chevron.left.forwardslash.chevron.right`) + mini capsule bar (≈16×4 pt, track at 30 % opacity, filled part solid) + percent text (`9%`, system 11–12 pt, monospaced digits). When the weekly value is shown, use a hollow/outlined track or a tiny "W" so session vs weekly is distinguishable. No data → "–". Both items in one image, ~8 pt apart; height fits the menu bar (≈ 18 pt).
- **Popover** (width ≈ 340, padding 18–20, matching the reference):
  - Header row: title "Code Usage" (bold) on the left; icon buttons on the right: chart (`chart.line.uptrend.xyaxis` → History window), gear (Settings window), refresh (`arrow.clockwise`, rotates/disabled while loading).
  - One section per provider (Claude first, divider between): header = provider name (semibold) + account name (secondary) + plan capsule badge (gray fill, e.g. "Team").
    Rows, as in the reference:
    - "현재 세션" (secondary, 13 pt) with burn rate right-aligned ("8.0%/hr", secondary) → big bold percent ("9%", ~26 pt) → capsule progress bar (height 8, track = provider color at 18 % opacity, fill = provider color; Claude terracotta `#D97757`, Codex `#5B8DEF`; fill turns `#E5484D` at ≥ 90 %) → "Resets in 2 hr 7 min (수, 16:40)" (secondary, 12 pt).
      If the plan has a session window but none is live → percent "0%", empty bar, caption "활성 세션 없음". If the plan has no session window at all (Codex here) → omit the row.
    - "주간 한도" row, same layout.
    - Extra windows (scoped weekly limits) as compact rows (label + small bar + percent + reset text).
    - If projected exhaustion is before reset → small orange caption "현재 속도면 16:05에 한도 도달".
    - Error: orange/red inline notice with `errorDescription`; keep showing the last snapshot (dimmed) if any. Not logged in → notice + no rows.
  - Footer: clock icon + `Fmt.relative(lastRefresh)` ("지금") on the left, copy button (`doc.on.doc`, copies `summaryText()`, brief checkmark feedback) on the right. Divider. Row "대시보드 열기" (chart icon) → `Menu` with "Claude 사용량 페이지" / "Codex 사용량 페이지" opening `ProviderID.dashboardURL`. Small "종료" button.
- Settings window (SwiftUI `Form`, ~420 wide): 새로고침 주기 (1/2/5/10/15 분), 토큰 자동 갱신 toggle with one-line explanation that it writes refreshed tokens back to the CLI store, menu bar toggles (Claude / Codex), 로그인 시 실행 (`SMAppService.mainApp` register/unregister, show error text on failure), credential source status (Claude Code Keychain item found? `~/.codex/auth.json` found?) — existence only, no secrets.
- History window: Swift Charts line chart, segmented 24시간 / 7일, one chart per provider, series 세션 / 주간 (y 0–100 %).
- `WindowManager`: opens/brings to front single instances of the Settings and History windows (`NSWindow` + `NSHostingController`), activating the app (`NSApp.activate`).

## Reference UI ("Usage for Claude" popover)
Rounded translucent popover. Header: "<account name> ▾" bold + gray "Team" capsule; right side outline icons (chart, gear, speech bubble, refresh).
Section "현재 세션" (gray small) with "8.0%/hr" right-aligned gray; "9%" large bold dark; thick rounded bar, terracotta fill on a pale pink track;
"Resets in 2 hr 7 min (수, 16:40)" gray. Section "주간 한도" "2%" same style, "Resets in 7 hr 27 min (수, 22:00)".
Footer: clock icon "지금" left, copy icon right. Then "대시보드 열기" with chart icon. Menu bar item: pill with a mini bar and "9%".
