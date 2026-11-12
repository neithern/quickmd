import SwiftUI

/// Settings window (⌘,): general behaviour + theme picker + document fonts +
/// external editor selection.
struct SettingsView: View {
    /// Remembered by identifier (`SettingsTab`); absent → the index SwiftUI
    /// remembered before, so an update does not move anyone's tab.
    @AppStorage(SettingsTab.defaultsKey) private var selectedTab: SettingsTab = SettingsTab.initial(in: .standard)

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ThemePickerView()
                .tabItem { Label("Themes", systemImage: "paintpalette") }
                .tag(SettingsTab.themes)
            FontPickerView()
                .tabItem { Label("Fonts", systemImage: "textformat") }
                .tag(SettingsTab.fonts)
            ExternalEditorPickerView()
                .tabItem { Label("Editor", systemImage: "pencil") }
                .tag(SettingsTab.editor)
        }
    }
}

// MARK: - General

/// Settings → General: document layout, selection behavior, window behavior,
/// and the Contents sidebar's depth.
struct GeneralSettingsView: View {
    @AppStorage(SelectionAutoCopy.defaultsKey) private var autoCopySelection: Bool = false
    @AppStorage(ToCDepth.defaultsKey) private var tocMaxLevel: Int = ToCDepth.all
    @AppStorage(WindowTabbing.separateWindowsKey) private var separateWindows: Bool = false
    @AppStorage(BlockLayout.Document.maximumPageWidthDefaultsKey)
    private var maximumPageWidth = BlockLayout.Document.defaultMaximumPageWidth

    /// Writes the setting and applies it to the documents opened from now on
    /// (`WindowTabbing.applyWindowPreference` lists what a running app can and
    /// cannot change).
    private var separateWindowsBinding: Binding<Bool> {
        Binding(
            get: { separateWindows },
            set: { newValue in
                separateWindows = newValue
                WindowTabbing.applyWindowPreference()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Toggle("Copy selected text automatically", isOn: $autoCopySelection)
                } header: {
                    Text("Selection")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                } footer: {
                    Text("Selected text is copied to the clipboard as soon as you finish selecting. Off by default because it replaces whatever you copied in another app.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle("Open documents in separate windows", isOn: separateWindowsBinding)
                } header: {
                    Text("Windows")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                } footer: {
                    // A switch to tabs reaches full screen only after a
                    // relaunch (AppKit caches the tabbing preference).
                    Text("Documents already open stay as they are. Takes full effect after restarting QuickMD.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section {
                    Picker("Show", selection: Binding(get: { ToCDepth.normalized(tocMaxLevel) },
                                                      set: { tocMaxLevel = $0 })) {
                        ForEach(ToCDepth.choices, id: \.maxLevel) { choice in
                            Text(choice.title).tag(choice.maxLevel)
                        }
                    }
                } header: {
                    Text("Contents Sidebar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                } footer: {
                    Text("Also in the sidebar's context menu.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section {
                    HStack(spacing: 12) {
                        Text("Maximum page width")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 12)
                        HStack(spacing: 6) {
                            TextField("", value: maximumPageWidthSelection,
                                      format: .number.precision(.fractionLength(0)))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .accessibilityLabel(Text("Maximum page width"))
                            Text("pt")
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("Page")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                } footer: {
                    Text("Maximum page width 0 means no width limit.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 360, height: 420)
    }

    private var maximumPageWidthSelection: Binding<Double> {
        Binding(get: { BlockLayout.Document.normalizedMaximumPageWidth(maximumPageWidth) },
                set: { maximumPageWidth = BlockLayout.Document.normalizedMaximumPageWidth($0) })
    }
}
