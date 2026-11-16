import SwiftUI
import UniformTypeIdentifiers

/// A few lines of shell output drawn with a theme and font, to judge both at a glance.
struct TerminalPreview: View {
    let theme: Theme
    let font: PlatformFont
    var lines = 5

    var body: some View {
        let p = theme.palette.map { Color(platform: PlatformColor(hex: $0)) }
        let fg = Color(platform: PlatformColor(hex: theme.fg))
        let f = Font(font)
        VStack(alignment: .leading, spacing: 2) {
            Text("~/code ").foregroundColor(p[4]) + Text("main ").foregroundColor(p[5])
                + Text("❯ ").foregroundColor(p[2]) + Text("git status").foregroundColor(fg)
            if lines > 1 {
                Text("modified:   ").foregroundColor(fg) + Text("server.go").foregroundColor(p[1])
            }
            if lines > 2 {
                Text("new file:   ").foregroundColor(fg) + Text("theme.swift").foregroundColor(p[2])
            }
            if lines > 3 {
                Text("warning: ").foregroundColor(p[3]).bold() + Text("0O 1lI {}=> != ").foregroundColor(fg)
                    + Text("\u{f418} \u{e725}").foregroundColor(p[6])
            }
            if lines > 4 {
                HStack(spacing: 3) {
                    ForEach(0..<16, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(p[i]).frame(width: 12, height: 12)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(f)
        .lineLimit(1)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(platform: PlatformColor(hex: theme.bg)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct AppearanceView: View {
    @ObservedObject private var a = Appearance.shared

    var body: some View {
        Form {
            Section {
                TerminalPreview(theme: a.theme(named: nil), font: a.font())
                    .listRowInsets(EdgeInsets())
            }
            Section {
                NavigationLink {
                    ThemePicker(selection: $a.themeName, allowDefault: false)
                } label: {
                    LabeledContent("Theme", value: a.themeName)
                }
                NavigationLink {
                    FontPicker()
                } label: {
                    LabeledContent("Font", value: a.fontName)
                }
                Stepper(value: $a.fontSize, in: 8...36, step: 1) {
                    LabeledContent("Size", value: "\(Int(a.fontSize)) pt")
                }
            } footer: {
                #if os(iOS)
                Text("In a terminal: ⌘+ and ⌘− change the size, ⌘0 resets it, pinch works too.")
                #else
                Text("In a terminal: ⌘= and ⌘− change the size, ⌘0 resets it.")
                #endif
            }
            Section("Cursor") {
                Picker("Shape", selection: $a.cursor) {
                    ForEach(CursorShape.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Blink", isOn: $a.cursorBlink)
            }
            Section {
                Toggle("Option key as Meta", isOn: $a.optionAsMeta)
            } footer: {
                Text("On: ⌥ sends Esc-prefixed keys (Emacs, readline word jumps). Off: ⌥ types special characters.")
            }
            Section {
                NavigationLink("Licenses") { LicensesView() }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Appearance")
    }
}

/// Searchable list of every theme. With allowDefault, the empty selection means
/// "use the global theme" (for per-server overrides).
struct ThemePicker: View {
    @Binding var selection: String
    let allowDefault: Bool
    @ObservedObject private var a = Appearance.shared
    @State private var query = ""
    @State private var filter = 0
    @State private var importing = false
    @State private var error: String?

    private var themes: [Theme] {
        a.allThemes.filter { t in
            (filter == 0 || (filter == 1) == t.isDark)
                && (query.isEmpty || t.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            Section {
                Picker("", selection: $filter) {
                    Text("All").tag(0)
                    Text("Dark").tag(1)
                    Text("Light").tag(2)
                }
                .pickerStyle(.segmented)
                if let error { Text(error).foregroundStyle(.red) }
                if allowDefault {
                    row(name: "Default (\(a.themeName))", value: "", theme: a.theme(named: nil))
                }
            }
            Section("\(themes.count) themes") {
                ForEach(themes) { t in
                    row(name: t.name, value: t.name, theme: t)
                        .swipeActions {
                            if a.isImported(t) {
                                Button("Delete", role: .destructive) { a.deleteImportedTheme(t) }
                            }
                        }
                }
            }
        }
        .searchable(text: $query, prompt: "Search themes")
        .navigationTitle("Theme")
        .toolbar {
            Button("Import", systemImage: "square.and.arrow.down") { importing = true }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            error = nil
            guard case .success(let urls) = result else { return }
            for url in urls {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                do {
                    let t = try a.importTheme(from: url)
                    if urls.count == 1 { selection = t.name }
                } catch {
                    self.error = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    private func row(name: String, value: String, theme: Theme) -> some View {
        Button { selection = value } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(.body, design: .monospaced))
                        .foregroundColor(Color(platform: PlatformColor(hex: theme.fg)))
                    HStack(spacing: 2) {
                        ForEach(1..<7, id: \.self) { i in
                            Circle().fill(Color(platform: PlatformColor(hex: theme.palette[i]))).frame(width: 9, height: 9)
                        }
                    }
                }
                Spacer()
                if selection == value {
                    Image(systemName: "checkmark").foregroundColor(Color(platform: PlatformColor(hex: theme.palette[2])))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color(platform: PlatformColor(hex: theme.bg)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
    }
}

struct FontPicker: View {
    @ObservedObject private var a = Appearance.shared
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(a.fonts) { f in
                Button { a.fontName = f.name } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(f.name).font(.caption).foregroundStyle(.secondary)
                            Text("0O 1lI {}=> \u{f418} \u{e725} ~/code ❯")
                                .font(Font(a.font(named: f.name, size: 17)))
                                .lineLimit(1)
                        }
                        Spacer()
                        if a.fontName == f.name { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    if f.imported {
                        Button("Delete", role: .destructive) { a.deleteImportedFont(f) }
                    }
                }
            }
        }
        .navigationTitle("Font")
        .toolbar {
            Button("Import", systemImage: "square.and.arrow.down") { importing = true }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.font], allowsMultipleSelection: true) { result in
            error = nil
            guard case .success(let urls) = result else { return }
            for url in urls {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                do {
                    let fam = try a.importFont(from: url)
                    if urls.count == 1 { a.fontName = fam }
                } catch {
                    self.error = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }
}

struct LicensesView: View {
    private var files: [URL] {
        var out: [URL] = []
        if let r = Bundle.main.resourceURL {
            let lic = r.appendingPathComponent("Fonts/licenses")
            out += ((try? FileManager.default.contentsOfDirectory(at: lic, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        if let t = Bundle.main.url(forResource: "themes-LICENSE", withExtension: "txt") { out.insert(t, at: 0) }
        return out
    }

    var body: some View {
        List(files, id: \.self) { url in
            NavigationLink(url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "themes-LICENSE", with: "Themes (iTerm2-Color-Schemes)")) {
                ScrollView {
                    Text((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                        .font(.caption.monospaced())
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("Licenses")
    }
}
