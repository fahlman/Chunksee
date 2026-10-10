import SwiftUI
import UniformTypeIdentifiers

/// Where player names come from: Minecraft's own name caches, and optionally Mojang.
struct SettingsView: View {
    @Bindable var names: PlayerNames
    @State private var isChoosingFolder = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Minecraft folder") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(names.minecraftFolder?.path(percentEncoded: false) ?? String(localized: "Not chosen"))
                            .foregroundStyle(names.minecraftFolder == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack {
                            if names.minecraftFolder != nil {
                                Button("Remove") { names.forgetMinecraftFolder() }
                            }
                            Button("Choose…") { isChoosingFolder = true }
                        }
                    }
                }
                Text("Minecraft remembers the names of players who have played on this Mac. Choose your Minecraft folder (usually Library ▸ Application Support ▸ minecraft in your home folder) so MCWorld can use them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Player Names on This Mac")
            }

            Section {
                Toggle("Look up other player names online", isOn: $names.looksUpOnline)
                Text("Asks Mojang for the current names of players this Mac doesn’t know. Only their player IDs are sent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !names.online.isEmpty {
                    Button("Forget Names Found Online") { names.clearOnlineNames() }
                }
            } header: {
                Text("Online")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await names.chooseMinecraftFolder(url) }
        }
        .fileDialogDefaultDirectory(Self.defaultMinecraftFolder)
    }

    /// The usual Minecraft folder, to open the panel there. Inside the sandbox the Foundation home
    /// directory APIs point at the app's container, so the real home comes from the user database.
    private static var defaultMinecraftFolder: URL? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: dir))
            .appendingPathComponent("Library/Application Support/minecraft", isDirectory: true)
    }
}
