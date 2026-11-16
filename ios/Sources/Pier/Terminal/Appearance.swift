import CoreText
import SwiftTerm
import SwiftUI

/// A terminal color theme. Colors are "#rrggbb".
struct Theme: Codable, Identifiable, Hashable {
    var name: String
    var bg: String
    var fg: String
    var cursor: String?
    var cursorText: String?
    var selection: String?
    var palette: [String]
    var id: String { name }

    var isDark: Bool { PlatformColor(hex: bg).luminance < 0.5 }
}

/// A font family the terminal can use.
struct FontFamily: Identifiable, Hashable {
    var name: String          // family name, shown to the user
    var regular: String       // PostScript name of the upright regular face
    var imported: Bool
    var id: String { name }
}

enum CursorShape: String, CaseIterable, Identifiable {
    case block, bar, underline
    var id: String { rawValue }

    func style(blink: Bool) -> CursorStyle {
        switch self {
        case .block: return blink ? .blinkBlock : .steadyBlock
        case .bar: return blink ? .blinkBar : .steadyBar
        case .underline: return blink ? .blinkUnderline : .steadyUnderline
        }
    }
}

/// Global look of every terminal: theme, font, size and cursor. A server can
/// override the theme (Host.theme).
@MainActor
final class Appearance: ObservableObject {
    static let shared = Appearance()
    static let defaultTheme = "Catppuccin Mocha"
    static let defaultFont = "JetBrainsMono Nerd Font Mono"
    static let systemFont = "SF Mono"

    @Published var themeName: String { didSet { save("themeName", themeName) } }
    @Published var fontName: String { didSet { save("fontName", fontName) } }
    @Published var fontSize: Double { didSet { save("fontSize", fontSize) } }
    @Published var cursor: CursorShape { didSet { save("cursor", cursor.rawValue) } }
    @Published var cursorBlink: Bool { didSet { save("cursorBlink", cursorBlink) } }
    @Published var optionAsMeta: Bool { didSet { save("optionAsMeta", optionAsMeta) } }
    @Published var predict: PredictMode { didSet { save("predict", predict.rawValue) } }
    @Published var showTmuxStatus: Bool { didSet { save("showTmuxStatus", showTmuxStatus) } }
    @Published var nativePanes: Bool { didSet { save("nativePanes", nativePanes) } }
    @Published private(set) var importedThemes: [Theme] = []
    @Published private(set) var fonts: [FontFamily] = []

    let builtInThemes: [Theme]

    private init() {
        let d = UserDefaults.standard
        themeName = d.string(forKey: "themeName") ?? Self.defaultTheme
        fontName = d.string(forKey: "fontName") ?? Self.defaultFont
        fontSize = d.object(forKey: "fontSize") as? Double ?? 14
        cursor = CursorShape(rawValue: d.string(forKey: "cursor") ?? "") ?? .block
        cursorBlink = d.object(forKey: "cursorBlink") as? Bool ?? true
        optionAsMeta = d.object(forKey: "optionAsMeta") as? Bool ?? true
        predict = d.string(forKey: "predict").flatMap(PredictMode.init(rawValue:)) ?? .auto
        showTmuxStatus = d.object(forKey: "showTmuxStatus") as? Bool ?? false
        nativePanes = d.object(forKey: "nativePanes") as? Bool ?? true
        if let url = Bundle.main.url(forResource: "themes", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let ts = try? JSONDecoder().decode([Theme].self, from: data) {
            builtInThemes = ts
        } else {
            builtInThemes = []
        }
        if let data = try? Data(contentsOf: Self.importedThemesURL),
           let ts = try? JSONDecoder().decode([Theme].self, from: data) {
            importedThemes = ts
        }
        registerFonts()
        #if os(macOS)
        // The Mac app bundles no fonts: a saved or default font that is not
        // on this Mac gives way to a Nerd Font that is, or to the system's.
        if !fonts.contains(where: { $0.name == fontName }) {
            fontName = fonts.first { $0.name.hasSuffix("Nerd Font Mono") }?.name ?? Self.systemFont
        }
        #endif
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    // MARK: Themes

    var allThemes: [Theme] { importedThemes + builtInThemes }

    func theme(named name: String?) -> Theme {
        let n = name ?? themeName
        return allThemes.first { $0.name == n }
            ?? allThemes.first { $0.name == themeName }
            ?? builtInThemes.first { $0.name == Self.defaultTheme }
            ?? Theme(name: "Default", bg: "#000000", fg: "#e5e5e5", palette: [
                "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
                "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff"])
    }

    func isImported(_ t: Theme) -> Bool { importedThemes.contains { $0.name == t.name } }

    private static var supportDir: URL { Paths.support }

    private static var importedThemesURL: URL { supportDir.appendingPathComponent("themes.json") }

    private func saveImportedThemes() {
        if let d = try? JSONEncoder().encode(importedThemes) {
            try? d.write(to: Self.importedThemesURL, options: .atomic)
        }
    }

    /// Imports a Ghostty theme, an iTerm2 .itermcolors file or a Base16/Base24 YAML scheme.
    @discardableResult
    func importTheme(from url: URL) throws -> Theme {
        let data = try Data(contentsOf: url)
        var t = try ThemeParser.parse(data, filename: url.lastPathComponent)
        if builtInThemes.contains(where: { $0.name == t.name }) { t.name += " (imported)" }
        importedThemes.removeAll { $0.name == t.name }
        importedThemes.insert(t, at: 0)
        saveImportedThemes()
        return t
    }

    func deleteImportedTheme(_ t: Theme) {
        importedThemes.removeAll { $0.name == t.name }
        saveImportedThemes()
        if themeName == t.name { themeName = Self.defaultTheme }
    }

    // MARK: Fonts

    private static var importedFontsDir: URL {
        let u = supportDir.appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func fontFiles(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".ttf") || $0.lowercased().hasSuffix(".otf") }
            .map { dir.appendingPathComponent($0) }
    }

    private func registerFonts() {
        var found: [String: FontFamily] = [:]
        let bundled = Bundle.main.resourceURL.map { $0.appendingPathComponent("Fonts") }
        let sources = (bundled.map { fontFiles(in: $0).map { ($0, false) } } ?? [])
            + fontFiles(in: Self.importedFontsDir).map { ($0, true) }
        for (url, imported) in sources {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            for f in Self.faces(at: url) where f.upright {
                if found[f.family] == nil || f.regular {
                    found[f.family] = FontFamily(name: f.family, regular: f.postScript, imported: imported)
                }
            }
        }
        #if os(macOS)
        // The Mac app bundles no fonts: the fixed-pitch families installed on the Mac.
        for family in NSFontManager.shared.availableFontFamilies where found[family] == nil && !family.hasPrefix(".") {
            let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
            // A member is [PostScript name, style, weight, traits]; 5 is the regular weight.
            let upright = members.filter { (($0.count > 3 ? $0[3] as? UInt : nil) ?? 0) & NSFontTraitMask.italicFontMask.rawValue == 0 }
            let pick = upright.first { ($0.count > 2 ? $0[2] as? Int : nil) == 5 } ?? upright.first
            guard let ps = pick?.first as? String, NSFont(name: ps, size: 12)?.isFixedPitch == true else { continue }
            found[family] = FontFamily(name: family, regular: ps, imported: false)
        }
        found["Menlo"] = nil
        found["Courier New"] = nil
        #endif
        fonts = [FontFamily(name: Self.systemFont, regular: "", imported: false),
                 FontFamily(name: "Menlo", regular: "Menlo-Regular", imported: false),
                 FontFamily(name: "Courier New", regular: "CourierNewPSMT", imported: false)]
            + found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private struct Face {
        var family: String
        var postScript: String
        var upright: Bool
        var regular: Bool
    }

    private static func faces(at url: URL) -> [Face] {
        guard let ds = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return [] }
        return ds.compactMap { d in
            guard let fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String,
                  let ps = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String else { return nil }
            let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any]
            let sym = (traits?[kCTFontSymbolicTrait] as? UInt32) ?? 0
            let italic = sym & CTFontSymbolicTraits.traitItalic.rawValue != 0
            let bold = sym & CTFontSymbolicTraits.traitBold.rawValue != 0
            return Face(family: fam, postScript: ps, upright: !italic, regular: !italic && !bold)
        }
    }

    /// Copies a .ttf/.otf into the app and registers it.
    func importFont(from url: URL) throws -> String {
        let faces = Self.faces(at: url)
        guard let family = faces.first?.family else {
            throw TmxError(errorDescription: "Not a font file")
        }
        let dest = Self.importedFontsDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        registerFonts()
        return family
    }

    func deleteImportedFont(_ f: FontFamily) {
        for url in fontFiles(in: Self.importedFontsDir) where Self.faces(at: url).contains(where: { $0.family == f.name }) {
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: url)
        }
        registerFonts()
        if fontName == f.name { fontName = Self.defaultFont }
    }

    func font(named name: String? = nil, size: Double? = nil) -> PlatformFont {
        let s = CGFloat(size ?? fontSize)
        let n = name ?? fontName
        if let f = fonts.first(where: { $0.name == n }), !f.regular.isEmpty, let font = PlatformFont(name: f.regular, size: s) {
            return font
        }
        #if os(macOS)
        // The Mac app bundles no fonts. Without the default one, a Nerd Font
        // of the Mac's own, so the icons of prompts and file listings show.
        if n == Self.defaultFont, let f = fonts.first(where: { $0.name.hasSuffix("Nerd Font Mono") && !$0.regular.isEmpty }),
           let font = PlatformFont(name: f.regular, size: s) {
            return font
        }
        #endif
        return PlatformFont.monospacedSystemFont(ofSize: s, weight: .regular)
    }
}

// MARK: - Theme files

enum ThemeParser {
    static func parse(_ data: Data, filename: String) throws -> Theme {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "itermcolors" || data.starts(with: Data("<?xml".utf8)) || data.starts(with: Data("bplist".utf8)) {
            return try iterm(data, name: base)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TmxError(errorDescription: "Unreadable theme file")
        }
        if text.range(of: #"base0[0-9A-Fa-f]\s*:"#, options: .regularExpression) != nil {
            return try base16(text, name: base)
        }
        return try ghostty(text, name: base)
    }

    private static func hex(_ s: String) -> String? {
        var v = s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if v.hasPrefix("#") { v.removeFirst() }
        guard v.count == 6, v.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + v.lowercased()
    }

    /// Ghostty: "palette = 0=#rrggbb", "background = #rrggbb", ...
    static func ghostty(_ text: String, name: String) throws -> Theme {
        var pal = [String?](repeating: nil, count: 16)
        var kv: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
            if parts[0] == "palette" {
                let p = parts[1].split(separator: "=", maxSplits: 1)
                if p.count == 2, let i = Int(p[0].trimmingCharacters(in: .whitespaces)), (0..<16).contains(i) {
                    pal[i] = hex(String(p[1]))
                }
            } else if let c = hex(parts[1]) {
                kv[parts[0]] = c
            }
        }
        guard let bg = kv["background"], let fg = kv["foreground"], !pal.contains(where: { $0 == nil }) else {
            throw TmxError(errorDescription: "Not a theme: needs background, foreground and 16 palette colors")
        }
        return Theme(name: name, bg: bg, fg: fg, cursor: kv["cursor-color"], cursorText: kv["cursor-text"],
                     selection: kv["selection-background"], palette: pal.map { $0! })
    }

    /// iTerm2 .itermcolors property list.
    static func iterm(_ data: Data, name: String) throws -> Theme {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw TmxError(errorDescription: "Not an .itermcolors file")
        }
        func color(_ key: String) -> String? {
            guard let c = plist[key] as? [String: Any],
                  let r = c["Red Component"] as? Double, let g = c["Green Component"] as? Double,
                  let b = c["Blue Component"] as? Double else { return nil }
            func h(_ x: Double) -> String { String(format: "%02x", Int((min(max(x, 0), 1) * 255).rounded())) }
            return "#" + h(r) + h(g) + h(b)
        }
        let pal = (0..<16).map { color("Ansi \($0) Color") }
        guard let bg = color("Background Color"), let fg = color("Foreground Color"),
              !pal.contains(where: { $0 == nil }) else {
            throw TmxError(errorDescription: "The .itermcolors file is missing colors")
        }
        return Theme(name: name, bg: bg, fg: fg, cursor: color("Cursor Color"), cursorText: color("Cursor Text Color"),
                     selection: color("Selection Color"), palette: pal.map { $0! })
    }

    /// Base16 / Base24 YAML (classic flat keys or the newer "palette:" block).
    static func base16(_ text: String, name: String) throws -> Theme {
        var b: [String: String] = [:]
        var scheme: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let k = parts[0].lowercased()
            // Values may be quoted and followed by a comment: base00: "#1d2021" # ----
            if k.hasPrefix("base"), k.count == 6,
               let r = parts[1].range(of: #"[0-9a-fA-F]{6}"#, options: .regularExpression),
               let c = hex(String(parts[1][r])) {
                b[k] = c
            } else if k == "scheme" || k == "name" {
                scheme = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
        }
        let need = ["base00", "base02", "base03", "base05", "base07", "base08", "base0a", "base0b", "base0c", "base0d", "base0e"]
        guard need.allSatisfy({ b[$0] != nil }) else {
            throw TmxError(errorDescription: "Base16 scheme is missing colors")
        }
        // Base24 has its own bright colors (base12...base17); Base16 repeats the normal ones.
        let bright = ["base12", "base14", "base13", "base16", "base17", "base15"].compactMap { b[$0] }
        let normal = [b["base08"]!, b["base0b"]!, b["base0a"]!, b["base0d"]!, b["base0e"]!, b["base0c"]!]
        let pal = [b["base00"]!] + normal + [b["base05"]!] + [b["base03"]!]
            + (bright.count == 6 ? bright : normal) + [b["base07"]!]
        return Theme(name: scheme ?? name, bg: b["base00"]!, fg: b["base05"]!, cursor: b["base05"],
                     cursorText: b["base00"], selection: b["base02"], palette: pal)
    }
}

// MARK: - Colors

extension PlatformColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        // A grey or a named colour has no red, green and blue to ask for until converted.
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

extension SwiftTerm.Color {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: UInt16((v >> 16) & 0xff) * 257, green: UInt16((v >> 8) & 0xff) * 257,
                  blue: UInt16(v & 0xff) * 257)
    }
}

extension Theme {
    /// Applies the theme to a terminal view.
    @MainActor
    func apply(to tv: TerminalView) {
        tv.installColors(palette.map { SwiftTerm.Color(hex: $0) })
        tv.nativeForegroundColor = PlatformColor(hex: fg)
        tv.nativeBackgroundColor = PlatformColor(hex: bg)
        tv.caretColor = PlatformColor(hex: cursor ?? fg)
        tv.caretTextColor = cursorText.map { PlatformColor(hex: $0) }
        tv.selectedTextBackgroundColor = PlatformColor(hex: selection ?? fg).withAlphaComponent(0.35)
    }
}
