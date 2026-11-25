import Cocoa
import WebKit
import CommonCrypto

let ENDPOINT = "https://openapi.qoder.com.cn"
let REFRESH_INTERVAL: TimeInterval = 300
let PREVIEW_HEIGHT: CGFloat = 380

let fm = FileManager.default
let homeDir = fm.homeDirectoryForCurrentUser
let stateDir = homeDir.appendingPathComponent(".qoder-coo", isDirectory: true)
let logURL = stateDir.appendingPathComponent("coo.log")
let credsURL = stateDir.appendingPathComponent("credentials.json")
let snapshotURL = stateDir.appendingPathComponent("last.json")
let keysURL = stateDir.appendingPathComponent("keys.json")
let moneyURL = stateDir.appendingPathComponent("money.json")
let launchAgentURL = homeDir.appendingPathComponent("Library/LaunchAgents/com.qodercoo.app.plist")

let numberFmt: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = ","
    f.groupingSize = 3
    f.usesGroupingSeparator = true
    f.locale = Locale(identifier: "en_US_POSIX")
    f.maximumFractionDigits = 0
    return f
}()

let netSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 20
    c.timeoutIntervalForResource = 30
    c.httpAdditionalHeaders = ["User-Agent": "QoderCoo/1.0"]
    return URLSession(configuration: c)
}()

func ensureStateDir() {
    try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
}

func logLine(_ s: String) {
    ensureStateDir()
    let df = DateFormatter()
    df.dateFormat = "MM-dd HH:mm:ss"
    let line = "[\(df.string(from: Date()))] \(s)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: logURL)
    }
    FileHandle.standardError.write(data)
}

func trimLogIfNeeded() {
    if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
       let size = attrs[.size] as? Int, size > 512_000,
       let data = try? Data(contentsOf: logURL) {
        try? Data(data.suffix(64_000)).write(to: logURL)
    }
}

func fmtInt(_ v: Double) -> String {
    numberFmt.string(from: NSNumber(value: Int(v.rounded()))) ?? String(Int(v.rounded()))
}

func fmtCompact(_ v: Double) -> String {
    if v >= 100_000 { return String(format: "%.0fk", v / 1000) }
    if v >= 10_000 { return String(format: "%.1fk", v / 1000) }
    return fmtInt(v)
}

enum Provider: String, CaseIterable {
    case qoder, deepseek, kimi

    var title: String {
        switch self {
        case .qoder: return "Qoder"
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi"
        }
    }

    var tag: String { title.uppercased() }
    var usesCredits: Bool { self == .qoder }

    var consoleURL: String {
        switch self {
        case .qoder: return "https://qoder.cn/account/usage"
        case .deepseek: return "https://platform.deepseek.com/api_keys"
        case .kimi: return "https://platform.moonshot.cn/console/api-keys"
        }
    }

    var usageURL: String {
        switch self {
        case .qoder: return "https://qoder.cn/account/usage"
        case .deepseek: return "https://platform.deepseek.com/usage"
        case .kimi: return "https://platform.moonshot.cn/console/account"
        }
    }
}

func currencySymbol(_ c: String) -> String { c == "USD" ? "$" : "¥" }

func fmtMoney(_ v: Double, _ currency: String) -> String {
    currencySymbol(currency) + String(format: "%.2f", v)
}

func fmtMoneyCompact(_ v: Double, _ currency: String) -> String {
    let sym = currencySymbol(currency)
    if v >= 10_000 { return sym + String(format: "%.1f万", v / 10_000) }
    if v >= 1000 { return sym + fmtInt(v) }
    return sym + String(format: "%.2f", v)
}

func relativeTime(_ ts: Double) -> String {
    guard ts > 0 else { return "尚未更新" }
    let delta = Date().timeIntervalSince1970 - ts
    if delta < 5 { return "刚刚更新" }
    if delta < 60 { return "\(Int(delta)) 秒前" }
    if delta < 3600 { return "\(Int(delta / 60)) 分钟前" }
    if delta < 86400 { return "\(Int(delta / 3600)) 小时前" }
    let df = DateFormatter()
    df.locale = Locale(identifier: "zh_CN")
    df.dateFormat = "M/d HH:mm"
    return df.string(from: Date(timeIntervalSince1970: ts))
}

func dayLabel(_ ms: Double?) -> String {
    guard let ms = ms, ms > 0 else { return "" }
    let df = DateFormatter()
    df.locale = Locale(identifier: "zh_CN")
    df.dateFormat = "M/d"
    return df.string(from: Date(timeIntervalSince1970: ms / 1000))
}

func resetLabel(_ ms: Double?) -> String {
    let day = dayLabel(ms)
    return day.isEmpty ? "" : day + " 重置"
}

func num(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String, let d = Double(s) { return d }
    return nil
}

func findString(_ object: Any, keys: [String]) -> String? {
    let wanted = Set(keys.map { $0.lowercased() })
    var queue: [(Any, Int)] = [(object, 0)]
    var index = 0
    while index < queue.count {
        let (obj, depth) = queue[index]
        index += 1
        if depth > 10 { continue }
        if let dict = obj as? [String: Any] {
            for (k, v) in dict {
                if wanted.contains(k.lowercased()), let s = v as? String, !s.isEmpty { return s }
            }
            for (_, v) in dict {
                if v is [String: Any] || v is [Any] { queue.append((v, depth + 1)) }
            }
        } else if let arr = obj as? [Any] {
            for v in arr {
                if v is [String: Any] || v is [Any] { queue.append((v, depth + 1)) }
            }
        }
    }
    return nil
}

struct Usage: Codable {
    var total: Double
    var used: Double
    var remaining: Double
    var addOnTotal: Double
    var addOnRemaining: Double
    var resetAt: Double?
    var exceeded: Bool
    var packageTitle: String?
    var packageRemaining: Double?
    var packageTotal: Double?
    var packageExpiresAt: Double?
    var fetchedAt: Double = Date().timeIntervalSince1970

    var remainingFraction: Double {
        guard total > 0 else { return 0 }
        return max(0, min(1, remaining / total))
    }

    var usedPercent: Int {
        guard total > 0 else { return 0 }
        return Int((100 * used / total).rounded())
    }

    static func from(json data: Data) -> Usage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let q = root["qoderUsage"] as? [String: Any] else { return nil }
        let uq = q["userQuota"] as? [String: Any] ?? [:]
        let aq = q["addOnQuota"] as? [String: Any] ?? [:]
        let total = num(uq["total"]) ?? 0
        let used = num(uq["used"]) ?? 0
        let remaining = num(uq["remaining"]) ?? max(0, total - used)
        var usage = Usage(
            total: total,
            used: used,
            remaining: remaining,
            addOnTotal: num(aq["total"]) ?? 0,
            addOnRemaining: num(aq["remaining"]) ?? 0,
            resetAt: num(q["refreshAt"]) ?? num(q["expiresAt"]),
            exceeded: (q["isQuotaExceeded"] as? Bool) ?? false,
            packageTitle: nil, packageRemaining: nil, packageTotal: nil, packageExpiresAt: nil,
            fetchedAt: Date().timeIntervalSince1970
        )
        if let packages = q["dedicatedResourcePackages"] as? [[String: Any]] {
            let active = packages.filter { (num($0["remaining"]) ?? 0) > 0 && (($0["available"] as? Bool) ?? true) }
            if let p = active.first {
                usage.packageTitle = packageTitle(p)
                usage.packageRemaining = num(p["remaining"])
                usage.packageTotal = num(p["total"])
                usage.packageExpiresAt = num(p["expiresAt"])
            }
        }
        return usage
    }

    static func packageTitle(_ p: [String: Any]) -> String? {
        if let labels = p["displayLabels"] as? [[String: Any]] {
            for l in labels where (l["dimension"] as? String) == "title" {
                if let i18n = l["valueI18n"] as? [String: Any], let zh = i18n["zh-CN"] as? String { return zh }
                if let v = l["value"] as? String { return v }
            }
        }
        return p["name"] as? String
    }

    static func sample(remaining: Double = 3994, total: Double = 6000, addon: Double = 500) -> Usage {
        Usage(total: total, used: total - remaining, remaining: remaining,
              addOnTotal: 600, addOnRemaining: addon,
              resetAt: Date().addingTimeInterval(86400 * 5).timeIntervalSince1970 * 1000,
              exceeded: false, packageTitle: "Qwen 专属积分", packageRemaining: 1992,
              packageTotal: 2000, packageExpiresAt: Date().addingTimeInterval(86400 * 2).timeIntervalSince1970 * 1000,
              fetchedAt: Date().timeIntervalSince1970)
    }
}

func saveSnapshot(_ usage: Usage) {
    ensureStateDir()
    if let data = try? JSONEncoder().encode(usage) {
        try? data.write(to: snapshotURL, options: .atomic)
    }
}

func loadSnapshot() -> Usage? {
    if let data = try? Data(contentsOf: snapshotURL), let u = try? JSONDecoder().decode(Usage.self, from: data) {
        return u
    }
    let legacy = homeDir.appendingPathComponent(".qoder-pet/last.json")
    if let data = try? Data(contentsOf: legacy), let u = try? JSONDecoder().decode(Usage.self, from: data) {
        return u
    }
    return nil
}

struct MoneyBalance: Codable {
    var provider: String
    var amount: Double
    var currency: String
    var granted: Double = 0
    var toppedUp: Double = 0
    var voucher: Double = 0
    var cash: Double = 0
    var available: Bool = true
    var fetchedAt: Double = Date().timeIntervalSince1970
}

func loadMoneySnapshots() -> [String: MoneyBalance] {
    guard let data = try? Data(contentsOf: moneyURL),
          let all = try? JSONDecoder().decode([String: MoneyBalance].self, from: data) else { return [:] }
    return all
}

func writeMoneySnapshots(_ all: [String: MoneyBalance]) {
    ensureStateDir()
    if let data = try? JSONEncoder().encode(all) {
        try? data.write(to: moneyURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: moneyURL.path)
    }
}

func saveMoneySnapshot(_ b: MoneyBalance) {
    var all = loadMoneySnapshots()
    all[b.provider] = b
    writeMoneySnapshots(all)
}

func removeMoneySnapshot(_ provider: Provider) {
    var all = loadMoneySnapshots()
    all.removeValue(forKey: provider.rawValue)
    writeMoneySnapshots(all)
}

struct APIKeys: Codable {
    var deepseek: String?
    var kimi: String?
}

enum KeyStore {
    static func load() -> APIKeys {
        guard let data = try? Data(contentsOf: keysURL),
              let keys = try? JSONDecoder().decode(APIKeys.self, from: data) else { return APIKeys() }
        return keys
    }

    static func key(for provider: Provider) -> String {
        let keys = load()
        let raw: String?
        switch provider {
        case .qoder: return ""
        case .deepseek: raw = keys.deepseek
        case .kimi: raw = keys.kimi
        }
        return (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func set(_ key: String, for provider: Provider) {
        guard provider != .qoder else { return }
        var keys = load()
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .deepseek { keys.deepseek = value } else { keys.kimi = value }
        save(keys)
    }

    static func clear(_ provider: Provider) {
        guard provider != .qoder else { return }
        var keys = load()
        if provider == .deepseek { keys.deepseek = nil } else { keys.kimi = nil }
        save(keys)
    }

    private static func save(_ keys: APIKeys) {
        ensureStateDir()
        if let data = try? JSONEncoder().encode(keys) {
            try? data.write(to: keysURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysURL.path)
        }
    }

    static func masked(_ key: String) -> String {
        if key.isEmpty { return "" }
        if key.count <= 8 { return String(key.prefix(2)) + "****" }
        return String(key.prefix(3)) + "…" + String(key.suffix(4))
    }
}

struct Credentials: Codable {
    var token: String
    var refreshToken: String?
    var expiresAt: String?
    var source: String
    var savedAt: Double
}

struct FoundToken {
    var token: String
    var refreshToken: String?
    var expiresAt: String?
    var source: String
}

enum CredStore {
    static func load() -> Credentials? {
        if let data = try? Data(contentsOf: credsURL),
           let c = try? JSONDecoder().decode(Credentials.self, from: data) {
            return c
        }
        let legacy = homeDir.appendingPathComponent(".qoder-pet/credentials.json")
        if let data = try? Data(contentsOf: legacy),
           let c = try? JSONDecoder().decode(Credentials.self, from: data) {
            save(FoundToken(token: c.token, refreshToken: c.refreshToken, expiresAt: c.expiresAt, source: c.source))
            return c
        }
        return nil
    }

    static func save(_ found: FoundToken) {
        ensureStateDir()
        let old = (try? Data(contentsOf: credsURL)).flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
        let creds = Credentials(
            token: found.token,
            refreshToken: found.refreshToken ?? old?.refreshToken,
            expiresAt: found.expiresAt ?? old?.expiresAt,
            source: found.source,
            savedAt: Date().timeIntervalSince1970
        )
        if let data = try? JSONEncoder().encode(creds) {
            try? data.write(to: credsURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credsURL.path)
        }
    }

    static func clear() {
        try? fm.removeItem(at: credsURL)
    }
}

func keychainPassword(service: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
}

func pbkdf2Key(password: String, salt: String, iterations: UInt32, keyLen: Int) -> [UInt8]? {
    var key = [UInt8](repeating: 0, count: keyLen)
    let saltBytes = Array(salt.utf8)
    let pwLen = password.utf8.count
    let status: Int32 = password.withCString { pw in
        saltBytes.withUnsafeBufferPointer { sp in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pwLen,
                                 sp.baseAddress, sp.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                 iterations, &key, keyLen)
        }
    }
    return status == kCCSuccess ? key : nil
}

func decryptV10(_ raw: Data, password: String) -> Data? {
    var data = raw
    if !data.starts(with: [0x76, 0x31, 0x30]) {
        if let s = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let d = Data(base64Encoded: s), d.starts(with: [0x76, 0x31, 0x30]) {
            data = d
        }
    }
    guard data.count > 3, data.starts(with: [0x76, 0x31, 0x30]) else { return nil }
    let cipher = data.subdata(in: 3..<data.count)
    guard let key = pbkdf2Key(password: password, salt: "saltysalt", iterations: 1003, keyLen: 16) else { return nil }
    let iv = [UInt8](repeating: 0x20, count: 16)
    var out = [UInt8](repeating: 0, count: cipher.count + 16)
    var outLen = 0
    let status: Int32 = key.withUnsafeBytes { kb in
        iv.withUnsafeBytes { ivb in
            cipher.withUnsafeBytes { cb in
                out.withUnsafeMutableBytes { ob in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            kb.baseAddress, key.count, ivb.baseAddress,
                            cb.baseAddress, cipher.count,
                            ob.baseAddress, ob.count, &outLen)
                }
            }
        }
    }
    guard status == kCCSuccess else { return nil }
    return Data(out.prefix(outLen))
}

func parseAuthPayload(_ data: Data, source: String) -> FoundToken? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
    guard let token = findString(obj, keys: ["token", "accessToken", "access_token", "deviceToken"]) else { return nil }
    return FoundToken(
        token: token,
        refreshToken: findString(obj, keys: ["refreshToken", "refresh_token"]),
        expiresAt: findString(obj, keys: ["expiresAt", "expires_at"]),
        source: source
    )
}

func extractFromDesktopApp() -> FoundToken? {
    let url = homeDir.appendingPathComponent("Library/Application Support/com.qodercn.app.stable/auth.v1.dat")
    guard let raw = try? Data(contentsOf: url) else { return nil }
    logLine("desktop auth file found (\(raw.count) bytes), requesting keychain")
    guard let pw = keychainPassword(service: "Qoder CN App Safe Storage") else {
        logLine("keychain denied: Qoder CN App Safe Storage")
        return nil
    }
    guard let dec = decryptV10(raw, password: pw) else {
        logLine("desktop auth decrypt failed")
        return nil
    }
    guard let found = parseAuthPayload(dec, source: "desktop-app") else {
        logLine("desktop auth payload has no token")
        return nil
    }
    logLine("desktop token extracted")
    return found
}

func sqliteHexValue(dbPath: String, key: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = [dbPath, "select hex(value) from ItemTable where key='\(key)' limit 1;"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func decodeHex(_ s: String) -> Data? {
    let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(clean.count / 2)
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }
        bytes.append(b)
        i = j
    }
    return Data(bytes)
}

func extractFromIDE() -> FoundToken? {
    let dbPath = homeDir.appendingPathComponent("Library/Application Support/QoderCN/User/globalStorage/state.vscdb").path
    guard fm.fileExists(atPath: dbPath) else { return nil }
    guard let hex = sqliteHexValue(dbPath: dbPath, key: "secret://aicoding.auth.userInfo"),
          let raw = decodeHex(hex) else {
        logLine("ide secret not found")
        return nil
    }
    logLine("ide secret found (\(raw.count) bytes)")
    var payload = raw
    if raw.first == UInt8(ascii: "{") {
        if let obj = try? JSONSerialization.jsonObject(with: raw) {
            if let token = findString(obj, keys: ["token", "accessToken", "access_token"]) {
                logLine("ide payload is plain json token")
                return FoundToken(
                    token: token,
                    refreshToken: findString(obj, keys: ["refreshToken", "refresh_token"]),
                    expiresAt: findString(obj, keys: ["expiresAt", "expires_at"]),
                    source: "ide"
                )
            }
            if let dict = obj as? [String: Any], let arr = dict["data"] as? [Any] {
                var bytes = [UInt8]()
                for v in arr {
                    if let n = num(v) { bytes.append(UInt8(clamping: Int(n))) }
                }
                payload = Data(bytes)
            }
        }
    }
    if let s = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !s.hasPrefix("v10"), let d = Data(base64Encoded: s) {
        payload = d
    }
    guard let pw = keychainPassword(service: "Qoder CN Safe Storage") else {
        logLine("keychain denied: Qoder CN Safe Storage")
        return nil
    }
    guard let dec = decryptV10(payload, password: pw) else {
        logLine("ide secret decrypt failed")
        return nil
    }
    guard let found = parseAuthPayload(dec, source: "ide") else {
        logLine("ide payload has no token")
        return nil
    }
    logLine("ide token extracted")
    return found
}

func discoverToken() -> FoundToken? {
    if let t = extractFromDesktopApp() {
        CredStore.save(t)
        return t
    }
    if let t = extractFromIDE() {
        CredStore.save(t)
        return t
    }
    return nil
}

struct HTTPResult {
    let status: Int
    let data: Data
}

func httpSync(_ request: URLRequest) -> HTTPResult? {
    let sem = DispatchSemaphore(value: 0)
    var result: HTTPResult?
    netSession.dataTask(with: request) { data, response, error in
        if let error = error {
            logLine("network error: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, let data = data {
            result = HTTPResult(status: http.statusCode, data: data)
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 35)
    return result
}

enum UsageError: Error {
    case unauthorized
    case network(String)

    var message: String {
        switch self {
        case .unauthorized: return "登录凭证已失效"
        case .network(let m): return m
        }
    }
}

func fetchUsage(token: String) -> Result<Usage, UsageError> {
    guard let url = URL(string: ENDPOINT + "/sash/api/v2/me/usage") else { return .failure(.network("地址无效")) }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.cachePolicy = .reloadIgnoringLocalCacheData
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
    guard let res = httpSync(req) else { return .failure(.network("网络连接失败")) }
    if res.status == 401 || res.status == 403 { return .failure(.unauthorized) }
    guard res.status == 200 else { return .failure(.network("HTTP \(res.status)")) }
    guard let usage = Usage.from(json: res.data) else { return .failure(.network("响应解析失败")) }
    return .success(usage)
}

func refreshDeviceToken(_ refreshToken: String) -> FoundToken? {
    guard let url = URL(string: ENDPOINT + "/api/v1/deviceToken/refresh") else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.cachePolicy = .reloadIgnoringLocalCacheData
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
    guard let res = httpSync(req) else { return nil }
    logLine("token refresh HTTP \(res.status)")
    guard res.status == 200,
          let obj = try? JSONSerialization.jsonObject(with: res.data),
          let token = findString(obj, keys: ["token", "accessToken", "access_token", "deviceToken"]) else {
        return nil
    }
    return FoundToken(
        token: token,
        refreshToken: findString(obj, keys: ["refreshToken", "refresh_token"]) ?? refreshToken,
        expiresAt: findString(obj, keys: ["expiresAt", "expires_at"]),
        source: "refresh"
    )
}

func friendlyHTTPError(_ status: Int) -> String {
    switch status {
    case 401: return "API Key 无效或已失效（401）"
    case 403: return "这个 Key 没有权限查询余额（403）"
    case 429: return "请求太频繁，请稍后再试（429）"
    case 404: return "接口地址不存在（404）"
    default: return "请求失败（HTTP \(status)）"
    }
}

func fetchDeepSeek(key: String) -> Result<MoneyBalance, UsageError> {
    guard let url = URL(string: "https://api.deepseek.com/user/balance") else { return .failure(.network("地址无效")) }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.cachePolicy = .reloadIgnoringLocalCacheData
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let res = httpSync(req) else { return .failure(.network("网络连接失败")) }
    guard res.status == 200 else { return .failure(.network(friendlyHTTPError(res.status))) }
    guard let root = try? JSONSerialization.jsonObject(with: res.data) as? [String: Any],
          let infos = root["balance_infos"] as? [[String: Any]], !infos.isEmpty else {
        return .failure(.network("接口没有返回余额信息"))
    }
    let entries = infos.map {
        (currency: ($0["currency"] as? String) ?? "CNY",
         total: num($0["total_balance"]) ?? 0,
         granted: num($0["granted_balance"]) ?? 0,
         toppedUp: num($0["topped_up_balance"]) ?? 0)
    }
    let primary = entries.first { $0.currency == "CNY" } ?? entries[0]
    return .success(MoneyBalance(
        provider: Provider.deepseek.rawValue,
        amount: primary.total,
        currency: primary.currency,
        granted: primary.granted,
        toppedUp: primary.toppedUp,
        available: (root["is_available"] as? Bool) ?? true,
        fetchedAt: Date().timeIntervalSince1970
    ))
}

func fetchKimi(key: String) -> Result<MoneyBalance, UsageError> {
    guard let url = URL(string: "https://api.moonshot.cn/v1/users/me/balance") else { return .failure(.network("地址无效")) }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.cachePolicy = .reloadIgnoringLocalCacheData
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let res = httpSync(req) else { return .failure(.network("网络连接失败")) }
    guard res.status == 200 else { return .failure(.network(friendlyHTTPError(res.status))) }
    guard let root = try? JSONSerialization.jsonObject(with: res.data) as? [String: Any],
          let d = root["data"] as? [String: Any] else {
        return .failure(.network("接口没有返回余额信息"))
    }
    return .success(MoneyBalance(
        provider: Provider.kimi.rawValue,
        amount: num(d["available_balance"]) ?? 0,
        currency: "CNY",
        voucher: num(d["voucher_balance"]) ?? 0,
        cash: num(d["cash_balance"]) ?? 0,
        fetchedAt: Date().timeIntervalSince1970
    ))
}

func fetchMoney(provider: Provider, key: String) -> Result<MoneyBalance, UsageError> {
    switch provider {
    case .deepseek: return fetchDeepSeek(key: key)
    case .kimi: return fetchKimi(key: key)
    case .qoder: return .failure(.network("Qoder 不走 API Key"))
    }
}

struct RefreshOutcome {
    var provider: String
    var usage: Usage?
    var money: MoneyBalance?
    var error: String?
    var needsAuth: Bool
}

func performQoderRefresh(forceRediscovery: Bool) -> RefreshOutcome {
    if forceRediscovery { CredStore.clear() }
    var creds = CredStore.load()
    if creds == nil, discoverToken() != nil {
        creds = CredStore.load()
    }
    guard let startCreds = creds else {
        return RefreshOutcome(provider: Provider.qoder.rawValue, usage: nil, money: nil,
                              error: "未找到登录凭证，请先打开 Qoder CN 登录", needsAuth: true)
    }
    var token = startCreds.token
    var result = fetchUsage(token: token)
    if case .failure(.unauthorized) = result {
        logLine("usage unauthorized, trying token refresh")
        var renewed: FoundToken?
        if let rt = startCreds.refreshToken, !rt.isEmpty {
            renewed = refreshDeviceToken(rt)
        }
        if renewed == nil { renewed = discoverToken() }
        if let r = renewed {
            CredStore.save(r)
            token = r.token
            result = fetchUsage(token: token)
        }
    }
    switch result {
    case .success(var usage):
        usage.fetchedAt = Date().timeIntervalSince1970
        saveSnapshot(usage)
        logLine("usage ok remaining=\(Int(usage.remaining)) used=\(Int(usage.used)) addon=\(Int(usage.addOnRemaining))")
        return RefreshOutcome(provider: Provider.qoder.rawValue, usage: usage, money: nil, error: nil, needsAuth: false)
    case .failure(.unauthorized):
        logLine("usage unauthorized after refresh")
        return RefreshOutcome(provider: Provider.qoder.rawValue, usage: nil, money: nil,
                              error: "登录凭证已失效，请重新登录 Qoder CN", needsAuth: true)
    case .failure(.network(let message)):
        logLine("usage failed: \(message)")
        return RefreshOutcome(provider: Provider.qoder.rawValue, usage: nil, money: nil, error: message, needsAuth: false)
    }
}

func performRefresh(provider: Provider, forceRediscovery: Bool) -> RefreshOutcome {
    switch provider {
    case .qoder:
        return performQoderRefresh(forceRediscovery: forceRediscovery)
    case .deepseek, .kimi:
        let key = KeyStore.key(for: provider)
        guard !key.isEmpty else {
            logLine("\(provider.rawValue) refresh skipped: no key")
            return RefreshOutcome(provider: provider.rawValue, usage: nil, money: nil,
                                  error: "还没有填写 \(provider.title) API Key", needsAuth: false)
        }
        switch fetchMoney(provider: provider, key: key) {
        case .success(var b):
            b.fetchedAt = Date().timeIntervalSince1970
            saveMoneySnapshot(b)
            logLine("\(provider.rawValue) balance \(fmtMoney(b.amount, b.currency)) available=\(b.available)")
            return RefreshOutcome(provider: provider.rawValue, usage: nil, money: b, error: nil, needsAuth: false)
        case .failure(let e):
            logLine("\(provider.rawValue) failed: \(e.message)")
            return RefreshOutcome(provider: provider.rawValue, usage: nil, money: nil, error: e.message, needsAuth: false)
        }
    }
}

final class BalanceService {
    private let queue = DispatchQueue(label: "qodercoo.service", qos: .utility)
    private var busy = false
    private var pending: (provider: Provider, rediscover: Bool)?
    var onOutcome: ((RefreshOutcome) -> Void)?

    func requestRefresh(provider: Provider, forceRediscovery: Bool = false) {
        if busy {
            pending = (provider, forceRediscovery)
            return
        }
        busy = true
        queue.async {
            let outcome = performRefresh(provider: provider, forceRediscovery: forceRediscovery)
            DispatchQueue.main.async {
                self.busy = false
                self.onOutcome?(outcome)
                if let next = self.pending {
                    self.pending = nil
                    self.requestRefresh(provider: next.provider, forceRediscovery: next.rediscover)
                }
            }
        }
    }
}

final class WebBundleHandler: NSObject, WKURLSchemeHandler {
    let root: URL

    init(root: URL) { self.root = root }

    private func mime(_ ext: String) -> String {
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var rel = url.path
        if rel.hasPrefix("/") { rel.removeFirst() }
        var file = root.appendingPathComponent(rel)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
            file = file.appendingPathComponent("index.html")
        }
        let rootPath = root.standardizedFileURL.path
        guard file.standardizedFileURL.path.hasPrefix(rootPath),
              let data = try? Data(contentsOf: file) else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain"])!
            task.didReceive(resp)
            task.didReceive(Data("not found".utf8))
            task.didFinish()
            logLine("web 404 \(rel)")
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime(file.pathExtension.lowercased()),
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
        ])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class CooPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CooWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func loadHeadImage() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "coo_head", withExtension: "png"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.size = NSSize(width: 18, height: 18)
    return img
}

func jsString(_ s: String) -> String {
    if let data = try? JSONEncoder().encode(s), let str = String(data: data, encoding: .utf8) {
        return str
    }
    return "\"\""
}

struct PreviewOptions {
    var snapshotPath: String?
    var delay: Double = 5
    var sample = false
    var bubble: String?
    var width: CGFloat?
    var height: CGFloat?
    var scale: Double?
    var scheme: String?
    var outfit: String?
}

final class CooController: NSObject, NSApplicationDelegate, NSMenuDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    let service = BalanceService()
    let panel: CooPanel
    let webView: CooWebView
    let statusItem: NSStatusItem
    let menu = NSMenu()
    let preview: PreviewOptions

    var usage: Usage?
    var money: [String: MoneyBalance]
    var lastError: String?
    var refreshing = false
    var bubbleWanted = false
    var webReady = false
    var hidden = false

    var provider: Provider
    var autoRefresh: Bool
    var scheme: String
    var outfit: String
    var sizeScale: Double
    var roam: Bool
    var showMenuBalance: Bool

    var layoutBox: CGRect?
    var pressing = false
    var dragHold = false
    var mouseTimer: Timer?
    var refreshTimer: Timer?
    var settingsWin: SettingsWindowController?
    var isPreview: Bool { preview.snapshotPath != nil }

    override init() {
        var opt = PreviewOptions()
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        opt.snapshotPath = value("--snapshot")
        if let d = value("--delay").flatMap(Double.init) { opt.delay = d }
        opt.sample = args.contains("--sample")
        opt.bubble = value("--bubble")
        if let w = value("--width").flatMap(Double.init) { opt.width = CGFloat(w) }
        if let h = value("--height").flatMap(Double.init) { opt.height = CGFloat(h) }
        if let s = value("--scale").flatMap(Double.init) { opt.scale = s }
        opt.scheme = value("--scheme")
        opt.outfit = value("--outfit")
        preview = opt

        let d = UserDefaults.standard
        provider = Provider(rawValue: d.string(forKey: "provider") ?? "") ?? .qoder
        autoRefresh = (d.object(forKey: "autoRefresh") as? Bool) ?? true
        money = loadMoneySnapshots()
        scheme = opt.scheme ?? d.string(forKey: "scheme") ?? "deepseek"
        outfit = opt.outfit ?? d.string(forKey: "outfit") ?? "maid"
        sizeScale = opt.scale ?? (d.object(forKey: "sizeScale") as? Double ?? 1.0)
        roam = (d.object(forKey: "roam") as? Bool) ?? true
        showMenuBalance = (d.object(forKey: "showMenuBalance") as? Bool) ?? true
        hidden = d.bool(forKey: "hidden")

        let screen = NSScreen.screens.first ?? NSScreen.main!
        let vf = screen.visibleFrame
        let width = opt.width ?? vf.width
        let x = opt.width != nil ? vf.midX - width / 2 : vf.minX
        let height = opt.snapshotPath != nil ? (opt.height ?? PREVIEW_HEIGHT) : vf.height
        panel = CooPanel(contentRect: NSRect(x: x, y: vf.minY, width: width, height: height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true

        let cfg = WKWebViewConfiguration()
        if let webRoot = Bundle.main.resourceURL?.appendingPathComponent("web") {
            cfg.setURLSchemeHandler(WebBundleHandler(root: webRoot), forURLScheme: "coo")
        }
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(
            source: "document.addEventListener('contextmenu', e => e.preventDefault());",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc
        cfg.suppressesIncrementalRendering = false

        webView = CooWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
        webView.layer?.backgroundColor = NSColor.clear.cgColor

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        usage = loadSnapshot()
        if opt.sample && usage == nil { usage = .sample() }

        super.init()

        service.onOutcome = { [weak self] outcome in self?.handleOutcome(outcome) }
        webView.navigationDelegate = self
        cfg.userContentController.add(self, name: "coo")
        panel.contentView = webView

        var comps = URLComponents()
        comps.scheme = "coo"
        comps.host = "app"
        comps.path = "/stage/"
        comps.queryItems = [
            URLQueryItem(name: "scale", value: String(sizeScale)),
            URLQueryItem(name: "scheme", value: scheme),
            URLQueryItem(name: "outfit", value: outfit),
            URLQueryItem(name: "roam", value: roam ? "1" : "0"),
        ]
        if let url = comps.url { webView.load(URLRequest(url: url)) }

        if let button = statusItem.button {
            button.image = loadHeadImage()
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleProportionallyDown
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
    }

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 QoderCoo",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 QoderCoo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 QoderCoo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        editItem.submenu = edit
        func addEdit(_ title: String, _ sel: String, _ key: String) {
            edit.addItem(withTitle: title, action: Selector(sel), keyEquivalent: key)
        }
        addEdit("撤销", "undo:", "z")
        addEdit("重做", "redo:", "Z")
        edit.addItem(.separator())
        addEdit("剪切", "cut:", "x")
        addEdit("拷贝", "copy:", "c")
        addEdit("粘贴", "paste:", "v")
        addEdit("全选", "selectAll:", "a")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        logLine("launch \(Bundle.main.bundlePath) preview=\(isPreview) hidden=\(hidden) provider=\(provider.rawValue) auto=\(autoRefresh)")
        trimLogIfNeeded()
        if isPreview {
            if preview.sample { usage = .sample() }
            placePanel(force: true)
            panel.orderFrontRegardless()
            panel.ignoresMouseEvents = false
            DispatchQueue.main.asyncAfter(deadline: .now() + preview.delay) { [weak self] in
                guard let self else { return }
                if let b = self.preview.bubble {
                    if b == "error" {
                        self.sendBubble(["ok": false, "error": "登录凭证已失效，请重新登录 Qoder CN",
                                         "when": "刚刚"], seconds: 60)
                    } else if b == "pending" {
                        self.sendBubble(["pending": true, "when": "正在查询"], seconds: 60)
                    } else if let u = self.usage {
                        self.sendBubble(self.payloadForQoder(u), seconds: 60)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.takeSnapshotAndExit()
                }
            }
            return
        }
        placePanel(force: true)
        if hidden {
            webView.evaluateJavaScript("window.coo && window.coo.setActive(false)", completionHandler: nil)
        } else {
            panel.orderFrontRegardless()
        }
        startMousePoll()
        if autoRefresh {
            startAutoRefresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.service.requestRefresh(provider: self.provider)
            }
        } else {
            logLine("auto refresh off, waiting for click")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.placePanel(force: true)
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.openSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logLine("terminate")
    }

    func placePanel(force: Bool = false) {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let w = preview.width ?? vf.width
        let x = preview.width != nil ? vf.midX - w / 2 : vf.minX
        let h = isPreview ? (preview.height ?? PREVIEW_HEIGHT) : vf.height
        let frame = NSRect(x: x, y: vf.minY, width: w, height: h)
        if force || panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func startMousePoll() {
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.pollMouse()
        }
        RunLoop.main.add(mouseTimer!, forMode: .common)
    }

    func startAutoRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: REFRESH_INTERVAL, repeats: true) { [weak self] _ in
            guard let self, self.autoRefresh else { return }
            self.service.requestRefresh(provider: self.provider)
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func pollMouse() {
        guard !hidden, panel.isVisible else { return }
        let p = NSEvent.mouseLocation
        let buttons = NSEvent.pressedMouseButtons
        if dragHold && buttons == 0 { dragHold = false }
        if !panel.frame.contains(p) {
            if buttons == 0 { setInteractive(false) }
            return
        }
        let x = p.x - panel.frame.minX
        let y = panel.frame.maxY - p.y
        var hit = false
        if let box = layoutBox {
            hit = box.insetBy(dx: -8, dy: -8).contains(NSPoint(x: x, y: y))
        }
        if buttons != 0 && (hit || pressing) { dragHold = true }
        setInteractive(hit || (buttons != 0 && (dragHold || pressing)))
    }

    func setInteractive(_ on: Bool) {
        if panel.ignoresMouseEvents == on {
            panel.ignoresMouseEvents = !on
        }
    }

    func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if button.image == nil { button.image = loadHeadImage() }
        guard showMenuBalance else { button.title = ""; return }
        if refreshing {
            button.title = "…"
            return
        }
        switch provider {
        case .qoder:
            button.title = usage.map { fmtCompact($0.remaining) } ?? "—"
        case .deepseek, .kimi:
            if let b = money[provider.rawValue] {
                button.title = fmtMoneyCompact(b.amount, b.currency)
            } else {
                button.title = "—"
            }
        }
    }

    func updateMenu() {
        menu.removeAllItems()

        func info(_ text: String, color: NSColor? = nil) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: color ?? NSColor.secondaryLabelColor,
            ])
            menu.addItem(item)
        }
        func action(_ title: String, _ sel: Selector, key: String = "", state: NSControl.StateValue = .off) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.target = self
            item.state = state
            menu.addItem(item)
        }

        info("数据源：\(provider.title)", color: .labelColor)
        switch provider {
        case .qoder:
            if let u = usage {
                info("剩余 \(fmtInt(u.remaining)) / \(fmtInt(u.total)) 积分 · 已用 \(u.usedPercent)%", color: .labelColor)
                if u.addOnTotal > 0 {
                    info("附加积分 \(fmtInt(u.addOnRemaining)) / \(fmtInt(u.addOnTotal))")
                }
                if let t = u.packageTitle, let r = u.packageRemaining, r > 0 {
                    var line = "\(t) 剩余 \(fmtInt(r))"
                    if let e = u.packageExpiresAt, e > 0 { line += "（\(dayLabel(e)) 到期）" }
                    info(line)
                }
                let reset = resetLabel(u.resetAt)
                if !reset.isEmpty { info(reset) }
                info("更新于 \(relativeTime(u.fetchedAt))")
            } else {
                info("尚未获取到余额数据")
            }
        case .deepseek, .kimi:
            if let b = money[provider.rawValue] {
                info("余额 \(fmtMoney(b.amount, b.currency)) \(b.currency)", color: .labelColor)
                var lines: [String] = []
                if b.toppedUp > 0 { lines.append("充值 " + fmtMoney(b.toppedUp, b.currency)) }
                if b.granted > 0 { lines.append("赠送 " + fmtMoney(b.granted, b.currency)) }
                if b.cash > 0 { lines.append("现金 " + fmtMoney(b.cash, b.currency)) }
                if b.voucher > 0 { lines.append("代金券 " + fmtMoney(b.voucher, b.currency)) }
                if !lines.isEmpty { info(lines.joined(separator: " · ")) }
                if !b.available { info("账户当前不可用", color: .systemOrange) }
                info("更新于 \(relativeTime(b.fetchedAt))")
            } else if KeyStore.key(for: provider).isEmpty {
                info("还没有填写 \(provider.title) API Key")
            } else {
                info("尚未获取到余额数据")
            }
        }
        if refreshing { info("正在刷新…", color: .systemBlue) }
        if let err = lastError, !err.isEmpty { info(err, color: .systemOrange) }

        menu.addItem(.separator())
        action("刷新余额", #selector(refreshNow), key: "r")
        action("让她说话", #selector(speakNow))

        let sourceRoot = NSMenuItem(title: "数据源", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu()
        for p in Provider.allCases {
            var title = p.usesCredits ? "Qoder 积分" : "\(p.title) 余额"
            if !p.usesCredits && KeyStore.key(for: p).isEmpty { title += "（未设置 Key）" }
            let item = NSMenuItem(title: title, action: #selector(selectProviderItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.rawValue
            item.state = provider == p ? .on : .off
            sourceMenu.addItem(item)
        }
        sourceRoot.submenu = sourceMenu
        menu.addItem(sourceRoot)
        action("设置 API Key…", #selector(openSettings), key: ",")
        if provider == .qoder {
            action("重新读取 Qoder 登录凭证", #selector(rediscover))
        }
        action("每 5 分钟自动刷新", #selector(toggleAutoRefresh), state: autoRefresh ? .on : .off)
        menu.addItem(.separator())
        action("打开用量页面", #selector(openUsagePage))
        menu.addItem(.separator())
        action(hidden ? "显示桌宠" : "隐藏桌宠", #selector(toggleHidden), key: "h")

        let skinRoot = NSMenuItem(title: "服装", action: nil, keyEquivalent: "")
        let skinMenu = NSMenu()
        for (id, title) in [("maid", "女仆装"), ("cape", "冬装"), ("crew", "店员装")] {
            let item = NSMenuItem(title: title, action: #selector(selectOutfit(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = outfit == id ? .on : .off
            skinMenu.addItem(item)
        }
        skinRoot.submenu = skinMenu
        menu.addItem(skinRoot)

        let schemeRoot = NSMenuItem(title: "配色", action: nil, keyEquivalent: "")
        let schemeMenu = NSMenu()
        let schemes = [("deepseek", "DeepSeek"), ("harness", "DeepSeek Harness"), ("chatgpt", "ChatGPT"),
                       ("claude", "Claude"), ("gemini", "Gemini"), ("kimi", "Kimi"),
                       ("minimax", "MiniMax"), ("qwen", "通义千问")]
        for (id, title) in schemes {
            let item = NSMenuItem(title: title, action: #selector(selectScheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = scheme == id ? .on : .off
            schemeMenu.addItem(item)
        }
        schemeRoot.submenu = schemeMenu
        menu.addItem(schemeRoot)

        let sizeRoot = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (tag, title) in [(70, "小"), (100, "中"), (125, "大")] {
            let item = NSMenuItem(title: title, action: #selector(selectSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = Int((sizeScale * 100).rounded()) == tag ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeRoot.submenu = sizeMenu
        menu.addItem(sizeRoot)

        action("自由活动", #selector(toggleRoam), state: roam ? .on : .off)
        menu.addItem(.separator())
        action("菜单栏显示余额", #selector(toggleMenuBalance), state: showMenuBalance ? .on : .off)
        action("开机自动启动", #selector(toggleAutostart), state: autostartEnabled() ? .on : .off)
        action("重新读取登录凭证", #selector(rediscover))
        action("打开数据文件夹", #selector(openDataFolder))
        menu.addItem(.separator())
        action("退出 QoderCoo", #selector(quitApp), key: "q")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenu()
    }

    @objc func refreshNow() {
        bubbleWanted = true
        refreshing = true
        updateStatusItem()
        if let cached = currentPayload() {
            sendBubble(cached, seconds: 12)
        } else {
            sendBubble(pendingPayload(), seconds: 20)
        }
        service.requestRefresh(provider: provider)
        pushSettingsState()
    }

    @objc func speakNow() {
        if let cached = currentPayload() {
            sendBubble(cached, seconds: 12)
        } else {
            refreshNow()
        }
    }

    @objc func rediscover() {
        guard provider == .qoder else { return }
        bubbleWanted = true
        refreshing = true
        lastError = nil
        updateStatusItem()
        sendBubble(pendingPayload(message: "正在重新读取 Qoder 凭证", when: "重新读取凭证"), seconds: 20)
        service.requestRefresh(provider: .qoder, forceRediscovery: true)
        pushSettingsState()
    }

    @objc func selectProviderItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let p = Provider(rawValue: id) else { return }
        selectProvider(p)
    }

    func selectProvider(_ p: Provider) {
        guard p != provider else { return }
        provider = p
        UserDefaults.standard.set(p.rawValue, forKey: "provider")
        lastError = nil
        refreshing = true
        updateStatusItem()
        bubbleWanted = true
        if let cached = currentPayload() {
            sendBubble(cached, seconds: 12)
        } else {
            sendBubble(pendingPayload(), seconds: 20)
        }
        service.requestRefresh(provider: p)
        pushSettingsState()
        logLine("provider \(p.rawValue)")
    }

    @objc func toggleAutoRefresh() {
        setAutoRefresh(!autoRefresh)
    }

    func setAutoRefresh(_ on: Bool) {
        guard autoRefresh != on else { return }
        autoRefresh = on
        UserDefaults.standard.set(on, forKey: "autoRefresh")
        if on {
            startAutoRefresh()
            refreshing = true
            updateStatusItem()
            service.requestRefresh(provider: provider)
        } else {
            stopAutoRefresh()
        }
        logLine("auto refresh \(on)")
        pushSettingsState()
    }

    @objc func openSettings() {
        if settingsWin == nil {
            settingsWin = SettingsWindowController { [weak self] body in
                self?.handleSettingsMessage(body)
            }
        }
        settingsWin?.show()
        pushSettingsState()
    }

    @objc func selectOutfit(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        outfit = id
        UserDefaults.standard.set(id, forKey: "outfit")
        applyScheme()
    }

    @objc func selectScheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        scheme = id
        UserDefaults.standard.set(id, forKey: "scheme")
        applyScheme()
    }

    func applyScheme() {
        js("window.coo && window.coo.setScheme(\(jsString(scheme)), \(jsString(outfit)))")
        logLine("skin \(scheme)-\(outfit)")
    }

    @objc func selectSize(_ sender: NSMenuItem) {
        sizeScale = Double(sender.tag) / 100.0
        UserDefaults.standard.set(sizeScale, forKey: "sizeScale")
        js("window.coo && window.coo.setScale(\(sizeScale))")
    }

    @objc func toggleRoam() {
        roam.toggle()
        UserDefaults.standard.set(roam, forKey: "roam")
        js("window.coo && window.coo.setRoam(\(roam ? "true" : "false"))")
    }

    @objc func toggleMenuBalance() {
        showMenuBalance.toggle()
        UserDefaults.standard.set(showMenuBalance, forKey: "showMenuBalance")
        updateStatusItem()
    }

    @objc func toggleHidden() {
        hidden.toggle()
        UserDefaults.standard.set(hidden, forKey: "hidden")
        if hidden {
            panel.orderOut(nil)
        } else {
            placePanel()
            panel.orderFrontRegardless()
            js("window.coo && window.coo.setActive(true)")
        }
        js("window.coo && window.coo.setActive(\(hidden ? "false" : "true"))")
    }

    @objc func toggleAutostart() {
        do {
            try setAutostart(!autostartEnabled())
            logLine("autostart \(autostartEnabled())")
        } catch {
            logLine("autostart error \(error.localizedDescription)")
        }
    }

    @objc func openUsagePage() {
        if let url = URL(string: provider.usageURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openDataFolder() {
        NSWorkspace.shared.open(stateDir)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func showContextMenu() {
        updateMenu()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func js(_ code: String) {
        guard webReady else { return }
        webView.evaluateJavaScript(code, completionHandler: nil)
    }

    func jsonLiteral(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    func sendBubble(_ payload: [String: Any], seconds: Double) {
        guard let s = jsonLiteral(payload) else { return }
        js("window.coo && window.coo.showBalance(\(s), \(seconds))")
    }

    func updateBubble(_ payload: [String: Any]) {
        guard let s = jsonLiteral(payload) else { return }
        js("window.coo && window.coo.updateBalance(\(s))")
    }

    func payloadForQoder(_ u: Usage) -> [String: Any] {
        [
            "ok": true,
            "kind": "credits",
            "tag": Provider.qoder.tag,
            "provider": Provider.qoder.title,
            "remaining": u.remaining,
            "total": u.total,
            "used": u.used,
            "addOnRemaining": u.addOnRemaining,
            "addOnTotal": u.addOnTotal,
            "reset": resetLabel(u.resetAt),
            "when": relativeTime(u.fetchedAt),
        ]
    }

    func payloadForMoney(_ b: MoneyBalance) -> [String: Any] {
        let p = Provider(rawValue: b.provider)
        var lines: [String] = []
        if b.toppedUp > 0 { lines.append("充值 " + fmtMoney(b.toppedUp, b.currency)) }
        if b.granted > 0 { lines.append("赠送 " + fmtMoney(b.granted, b.currency)) }
        if b.cash > 0 { lines.append("现金 " + fmtMoney(b.cash, b.currency)) }
        if b.voucher > 0 { lines.append("代金券 " + fmtMoney(b.voucher, b.currency)) }
        return [
            "ok": true,
            "kind": "money",
            "tag": p?.tag ?? "AI",
            "provider": p?.title ?? b.provider,
            "amount": b.amount,
            "currency": b.currency,
            "lines": lines,
            "available": b.available,
            "when": relativeTime(b.fetchedAt),
        ]
    }

    func currentPayload() -> [String: Any]? {
        switch provider {
        case .qoder:
            return usage.map(payloadForQoder)
        case .deepseek, .kimi:
            return money[provider.rawValue].map(payloadForMoney)
        }
    }

    func pendingPayload(message: String? = nil, when: String = "正在查询") -> [String: Any] {
        [
            "pending": true,
            "when": when,
            "tag": provider.tag,
            "provider": provider.title,
            "message": message ?? (provider == .qoder ? "让我看看今天的用量" : "让我看看 \(provider.title) 的余额"),
        ]
    }

    func errorPayload(_ message: String) -> [String: Any] {
        [
            "ok": false,
            "error": message,
            "when": "刚刚",
            "tag": provider.tag,
            "provider": provider.title,
            "hint": provider == .qoder ? "点菜单栏 → 重新读取 Qoder 登录凭证" : "点菜单栏 → 设置 API Key…",
        ]
    }

    func handleOutcome(_ outcome: RefreshOutcome) {
        refreshing = false
        let p = Provider(rawValue: outcome.provider) ?? .qoder
        if let u = outcome.usage { usage = u }
        if let b = outcome.money { money[p.rawValue] = b }
        guard p == provider else {
            updateStatusItem()
            pushSettingsState()
            return
        }
        lastError = outcome.error
        if let u = outcome.usage {
            logLine("outcome usage remaining=\(Int(u.remaining))")
        } else if let b = outcome.money {
            logLine("outcome \(p.rawValue) balance=\(fmtMoney(b.amount, b.currency))")
        }
        if bubbleWanted {
            if let payload = currentPayload() {
                sendBubble(payload, seconds: 12)
            } else {
                sendBubble(errorPayload(outcome.error ?? "查询失败"), seconds: 12)
            }
        } else if outcome.error == nil, let payload = currentPayload() {
            updateBubble(payload)
        }
        bubbleWanted = false
        updateStatusItem()
        pushSettingsState()
    }

    func settingsState() -> [String: Any] {
        var providers: [[String: Any]] = []
        for p in Provider.allCases {
            var entry: [String: Any] = ["id": p.rawValue, "title": p.title, "credits": p.usesCredits]
            if p.usesCredits {
                entry["note"] = "使用 Qoder CN 登录凭证，自动读取"
                entry["hasKey"] = true
            } else {
                let key = KeyStore.key(for: p)
                entry["note"] = p == .deepseek ? "api.deepseek.com" : "api.moonshot.cn"
                entry["hasKey"] = !key.isEmpty
                entry["mask"] = KeyStore.masked(key)
                entry["console"] = p.consoleURL
            }
            providers.append(entry)
        }
        var balance: Any = NSNull()
        if let payload = currentPayload() { balance = payload }
        return [
            "provider": provider.rawValue,
            "autoRefresh": autoRefresh,
            "providers": providers,
            "balance": balance,
            "refreshing": refreshing,
            "error": lastError ?? "",
            "folder": stateDir.path,
            "keysFile": keysURL.path,
        ]
    }

    func pushSettingsState() {
        settingsWin?.push(settingsState())
    }

    func handleSettingsMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready", "get":
            pushSettingsState()
        case "selectProvider":
            if let id = body["provider"] as? String, let p = Provider(rawValue: id) {
                selectProvider(p)
            }
            pushSettingsState()
        case "setAutoRefresh":
            setAutoRefresh((body["on"] as? Bool) ?? true)
            pushSettingsState()
        case "refresh":
            let p = (body["provider"] as? String).flatMap(Provider.init(rawValue:)) ?? provider
            refreshing = true
            updateStatusItem()
            service.requestRefresh(provider: p)
            pushSettingsState()
        case "saveKey":
            guard let id = body["provider"] as? String, let p = Provider(rawValue: id), p != .qoder else {
                settingsWin?.reply(["ok": false, "error": "Qoder 使用登录凭证，不需要填写 Key"])
                return
            }
            let key = (body["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                settingsWin?.reply(["ok": false, "error": "请先输入 API Key"])
                return
            }
            KeyStore.set(key, for: p)
            logLine("key saved for \(p.rawValue)")
            testProviderKey(p, key: key, save: true)
        case "testKey":
            guard let id = body["provider"] as? String, let p = Provider(rawValue: id), p != .qoder else {
                settingsWin?.reply(["ok": false, "error": "Qoder 使用登录凭证，不需要测试 Key"])
                return
            }
            var key = (body["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { key = KeyStore.key(for: p) }
            guard !key.isEmpty else {
                settingsWin?.reply(["ok": false, "error": "还没有保存 API Key"])
                return
            }
            testProviderKey(p, key: key, save: false)
        case "clearKey":
            guard let id = body["provider"] as? String, let p = Provider(rawValue: id), p != .qoder else { return }
            KeyStore.clear(p)
            removeMoneySnapshot(p)
            money[p.rawValue] = nil
            if provider == p { updateStatusItem() }
            logLine("key cleared for \(p.rawValue)")
            pushSettingsState()
            settingsWin?.reply(["ok": true, "cleared": true])
        case "openConsole":
            let p = (body["provider"] as? String).flatMap(Provider.init(rawValue:)) ?? provider
            if let url = URL(string: p.consoleURL) { NSWorkspace.shared.open(url) }
        case "openFolder":
            NSWorkspace.shared.open(stateDir)
        case "close":
            settingsWin?.closeWindow()
        default:
            break
        }
    }

    func testProviderKey(_ p: Provider, key: String, save: Bool) {
        DispatchQueue.global(qos: .utility).async {
            let result = fetchMoney(provider: p, key: key)
            DispatchQueue.main.async {
                switch result {
                case .success(var b):
                    b.fetchedAt = Date().timeIntervalSince1970
                    saveMoneySnapshot(b)
                    self.money[p.rawValue] = b
                    logLine("key test ok \(p.rawValue) \(fmtMoney(b.amount, b.currency))")
                    self.settingsWin?.reply([
                        "ok": true,
                        "amount": b.amount,
                        "currency": b.currency,
                        "when": relativeTime(b.fetchedAt),
                        "saved": save,
                        "mask": KeyStore.masked(KeyStore.key(for: p)),
                    ])
                    if self.provider == p {
                        self.lastError = nil
                        self.updateStatusItem()
                        self.bubbleWanted = true
                        self.sendBubble(self.payloadForMoney(b), seconds: 12)
                        self.bubbleWanted = false
                    }
                    self.pushSettingsState()
                case .failure(let e):
                    logLine("key test failed \(p.rawValue): \(e.message)")
                    self.settingsWin?.reply(["ok": false, "error": e.message, "saved": save])
                    self.pushSettingsState()
                }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            webReady = true
            logLine("web ready")
            js("window.coo && window.coo.setScale(\(sizeScale))")
            js("window.coo && window.coo.setRoam(\(roam ? "true" : "false"))")
            js("window.coo && window.coo.setActive(\(hidden ? "false" : "true"))")
        case "petClick":
            refreshNow()
        case "menu":
            showContextMenu()
        case "layout":
            if let b = body["box"] as? [String: Any],
               let x = num(b["x"]), let y = num(b["y"]),
               let w = num(b["w"]), let h = num(b["h"]) {
                layoutBox = CGRect(x: x, y: y, width: w, height: h)
            }
            pressing = (body["pressing"] as? Bool) ?? false
        case "jsError":
            logLine("js error: \(body["message"] as? String ?? "")")
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logLine("web didFinish")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logLine("web didFail \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        logLine("web didFailProv \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logLine("web content process terminated, reloading")
        webReady = false
        layoutBox = nil
        webView.reload()
    }

    func takeSnapshotAndExit() {
        webView.evaluateJavaScript("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))).then(() => true)") { _, _ in
            self.captureSnapshotAndExit()
        }
    }

    func captureSnapshotAndExit() {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = webView.bounds
        webView.takeSnapshot(with: cfg) { [weak self] img, err in
            guard let self else { return }
            if let img, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]),
               let path = self.preview.snapshotPath {
                try? png.write(to: URL(fileURLWithPath: path))
                print("snapshot \(path) \(Int(img.size.width))x\(Int(img.size.height))")
            } else {
                print("snapshot failed: \(String(describing: err))")
            }
            NSApp.terminate(nil)
        }
    }
}

func autostartEnabled() -> Bool {
    fm.fileExists(atPath: launchAgentURL.path)
}

final class SettingsWindowController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let window: NSWindow
    let webView: WKWebView
    var onMessage: (([String: Any]) -> Void)?
    private(set) var ready = false

    init(onMessage: @escaping ([String: Any]) -> Void) {
        self.onMessage = onMessage
        let rect = NSRect(x: 0, y: 0, width: 460, height: 620)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "QoderCoo 设置"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = NSColor.white
        if let screen = NSScreen.screens.first ?? NSScreen.main {
            let vf = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: vf.midX - rect.width / 2, y: vf.midY - rect.height / 2))
        }

        let cfg = WKWebViewConfiguration()
        if let webRoot = Bundle.main.resourceURL?.appendingPathComponent("web") {
            cfg.setURLSchemeHandler(WebBundleHandler(root: webRoot), forURLScheme: "coo")
        }
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        webView = WKWebView(frame: rect, configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")

        super.init()

        ucc.add(self, name: "settings")
        webView.navigationDelegate = self
        window.contentView = webView

        var comps = URLComponents()
        comps.scheme = "coo"
        comps.host = "app"
        comps.path = "/settings/"
        if let url = comps.url { webView.load(URLRequest(url: url)) }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeWindow() {
        window.performClose(nil)
    }

    private func call(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func push(_ state: [String: Any]) {
        guard ready, let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        call("window.settingsUI && window.settingsUI.apply(\(json))")
    }

    func reply(_ obj: [String: Any]) {
        guard ready, let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        call("window.settingsUI && window.settingsUI.result(\(json))")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let type = (body["type"] as? String) ?? "?"
        if type == "ready" { ready = true }
        logLine("settings msg \(type)")
        onMessage?(body)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        logLine("settings page loaded")
        onMessage?(["type": "get"])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logLine("settings didFail \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        logLine("settings didFailProv \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logLine("settings web process terminated, reloading")
        ready = false
        webView.reload()
    }
}

func setAutostart(_ enabled: Bool) throws {
    if enabled {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": "com.qodercoo.app",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: launchAgentURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: launchAgentURL.path)
    } else if fm.fileExists(atPath: launchAgentURL.path) {
        try fm.removeItem(at: launchAgentURL)
    }
}

var instanceLockFD: Int32 = -1

func acquireInstanceLock() -> Bool {
    ensureStateDir()
    let path = stateDir.appendingPathComponent("coo.lock").path
    instanceLockFD = path.withCString { Darwin.open($0, O_CREAT | O_RDWR, 0o600) }
    guard instanceLockFD >= 0 else { return true }
    return flock(instanceLockFD, LOCK_EX | LOCK_NB) == 0
}

let cliArgs = CommandLine.arguments

if cliArgs.contains("--once") {
    var cliProvider = Provider.qoder
    if let i = cliArgs.firstIndex(of: "--provider"), i + 1 < cliArgs.count,
       let p = Provider(rawValue: cliArgs[i + 1]) {
        cliProvider = p
    }
    let outcome = performRefresh(provider: cliProvider, forceRediscovery: cliArgs.contains("--rediscover"))
    if let u = outcome.usage {
        print("remaining=\(Int(u.remaining)) total=\(Int(u.total)) used=\(Int(u.used)) addon=\(Int(u.addOnRemaining))/\(Int(u.addOnTotal)) exceeded=\(u.exceeded)")
        print("reset=\(resetLabel(u.resetAt)) updated=\(relativeTime(u.fetchedAt))")
        if let t = u.packageTitle, let r = u.packageRemaining {
            print("package=\(t) remaining=\(Int(r))")
        }
        exit(0)
    } else if let b = outcome.money {
        print("provider=\(b.provider) balance=\(fmtMoney(b.amount, b.currency)) \(b.currency) available=\(b.available)")
        if b.toppedUp > 0 { print("toppedUp=\(fmtMoney(b.toppedUp, b.currency))") }
        if b.granted > 0 { print("granted=\(fmtMoney(b.granted, b.currency))") }
        if b.cash > 0 { print("cash=\(fmtMoney(b.cash, b.currency))") }
        if b.voucher > 0 { print("voucher=\(fmtMoney(b.voucher, b.currency))") }
        print("updated=\(relativeTime(b.fetchedAt))")
        exit(0)
    } else {
        print("ERROR: \(outcome.error ?? "unknown")")
        exit(1)
    }
}

if !acquireInstanceLock() {
    logLine("another instance is running, exiting")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = CooController()
app.delegate = controller
app.run()