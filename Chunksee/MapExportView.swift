import AppKit
import SwiftUI

struct MapExportView: View {
    let session: WorldSession
    @Bindable var model: MapExportModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    init(session: WorldSession) {
        self.session = session
        model = session.imageExport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Map Image").font(.title2.bold())
            Form {
                Picker("Area", selection: $model.options.area) {
                    ForEach(MapExportModel.Area.allCases, id: \.self) { area in
                        Text(area.title).tag(area)
                    }
                }
                .accessibilityIdentifier("map-export-area")
                if model.options.area == .measured {
                    Text("Includes the rectangle between both measurement points.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("Scale", selection: $model.options.blocksPerPixel) {
                        ForEach(MapExportPlan.blocksPerPixelChoices, id: \.self) { blocks in
                            if blocks == 1 { Text("1 pixel per block").tag(blocks) }
                            else { Text("1 pixel per \(blocks.formatted()) blocks").tag(blocks) }
                        }
                    }
                    .accessibilityIdentifier("map-export-scale")
                    Button("Fit Image") { model.fitImage() }
                        .help("Choose the most detailed scale that fits within the image size limit")
                }
                LabeledContent("View") { Text((model.renderedDepth ?? session.map?.depth)?.accessibilityDescription ?? "") }
                Toggle("Include Markers", isOn: $model.options.includesMarkers)
                Toggle("Include Grid", isOn: $model.options.includesGrid)
            }
            .disabled(model.isRunning)
            dimensions
            if let error = model.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("map-export-error")
            }
            if model.isRunning {
                if model.isCancelling {
                    ProgressView("Canceling…")
                } else if model.total > 0 {
                    ProgressView(value: Double(model.completed), total: Double(model.total)) {
                        Text("Creating Image…")
                    } currentValueLabel: {
                        Text("\(model.completed.formatted()) of \(model.total.formatted()) regions")
                    }
                } else {
                    ProgressView("Preparing Image…")
                }
            } else if let preview = model.preview {
                Image(decorative: preview, scale: 1)
                    .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 200)
                    .accessibilityHidden(true)
            } else if model.isReadingContent {
                Text("Waiting for the world’s markers and overlays to finish loading…")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Close") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.isRunning {
                    Button("Cancel") { model.cancel() }
                        .disabled(model.isCancelling)
                } else if let image = model.result {
                    Button("Copy Image") { image.copy(to: .general) }
                        .keyboardShortcut("c")
                    ShareLink(item: SharedMapImage { image },
                              preview: SharePreview(Text("Map Image"), image: Image(systemName: ItemAppearance.mapSymbol))) {
                        Label("Share Image", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button("Create Image") { model.create(colorScheme: colorScheme, locale: locale) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canCreate)
                        .accessibilityIdentifier("map-export-create")
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var dimensions: some View {
        switch model.preparedPlan.map(Result.success) ?? model.plan {
        case .success(let plan):
            Text("\(plan.width.formatted()) × \(plan.height.formatted()) pixels")
                .monospacedDigit().accessibilityIdentifier("map-export-dimensions")
            if let image = model.result {
                Text("PNG: \(Int64(image.data.count).formatted(.byteCount(style: .file)))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // Compression depends on the map; allow for incompressible data and PNG overhead.
                let estimate = Int64(plan.uncompressedBytes + plan.uncompressedBytes / 50 + 4096)
                Text("Estimated PNG size: up to about \(estimate.formatted(.byteCount(style: .file)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failure(let error):
            Text(error.localizedDescription).foregroundStyle(.secondary)
                .accessibilityIdentifier("map-export-dimensions")
        }
    }
}

extension MapImage {
    /// The native clipboard boundary takes an explicit board so tests use a private named board.
    @MainActor
    func copy(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }
}
