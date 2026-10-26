import ChunkseeKit
import SwiftUI

/// A temporary plan in the source document; it never inserts a portal into the saved index.
struct PortalPlanView: View {
    let session: WorldSession
    @Bindable var draft: PortalPlanDraft
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        let plan = draft.entrance.flatMap {
            PortalPlan(entrance: $0, dimension: draft.dimension, portals: session.presentation.portalsByDimension,
                       dimensionTypes: session.details.dimensionSettings.compactMapValues(\.type), borders: session.details.borders)
        }
        VStack(alignment: .leading, spacing: 16) {
            Label("Plan Portal", systemImage: PlaceGroup.portal.symbol).font(.headline)
            Form {
                Section {
                    LabeledContent("Dimension", value: session.presentation.dimensionName(draft.dimension))
                    LabeledContent("Coordinates") {
                        TextField("X Y Z", text: $draft.coordinates)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Proposed entrance coordinates")
                            .accessibilityIdentifier("portal-plan-coordinates")
                            .help("Enter whole X Y Z block coordinates separated by spaces")
                            .focused($isFocused)
                    }
                    if plan == nil {
                        Text("Enter X Y Z to see the matching location and portal link.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Proposed Entrance")
                } footer: {
                    Text("For terrain locations, the starting Y is the mapped surface. Use the portal entrance block’s height.")
                }
                if let plan {
                    Section("Matching Coordinates") {
                        CoordinateText(Coordinates(point(plan.destination), y: plan.destination.y),
                                       dimension: session.presentation.dimensionName(plan.targetDimension))
                        HStack {
                            CopyCoordinatesCommand(session: session, position: point(plan.destination),
                                                   dimension: plan.targetDimension, y: Double(plan.destination.y), pasteboard: .general)
                            Button("Show Matching Location") {
                                dismiss()
                                session.routing.focus(on: MapDestination(coordinates: Coordinates(point(plan.destination), y: plan.destination.y),
                                                                         dimension: plan.targetDimension, isBlockPosition: true))
                            }
                            .disabled(!session.routing.canFocus(Coordinates(point(plan.destination), y: plan.destination.y), in: plan.targetDimension))
                        }
                    }
                    Section {
                        switch plan.link {
                        case .portal(let portal, let block)?:
                            Text("Would link to the saved portal at:")
                            CoordinateText(Coordinates(point(block), y: block.y),
                                           dimension: session.presentation.dimensionName(portal.dimension))
                            HStack {
                                CopyCoordinatesCommand(session: session, position: point(block),
                                                       dimension: portal.dimension, y: Double(block.y), pasteboard: .general)
                                Button("Show the Other Side") {
                                    dismiss()
                                    session.selection.show(portal)
                                }
                                .disabled(!session.routing.canFocus(Coordinates(point(block), y: block.y), in: portal.dimension))
                            }
                        case .wouldCreateNewPortal?:
                            Text("No saved portal is close enough. Minecraft would try to create one near the matching coordinates.")
                        case nil:
                            if session.resources.index.isWaitingForPortals(in: plan.targetDimension) {
                                ProgressView("Reading portal links…").controlSize(.small)
                            } else {
                                Text("Saved portal data isn’t available for this dimension.").foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Link")
                    } footer: {
                        Text("Predicted from this entrance block and saved portals. A different entrance block can change the link.")
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { isFocused = true }
    }

    private func point(_ block: NetherPortal.Block) -> CGPoint { CGPoint(x: block.x, y: block.z) }
}

/// The same command in Navigate and location context menus, with a captured location when supplied.
struct PlanPortalCommand: View {
    let session: WorldSession?
    var position: CGPoint?
    var dimension: String?
    var y: Double?

    var body: some View {
        Button("Plan Portal Here…") { session?.annotations.planPortal(at: position, in: dimension, y: y) }
            .disabled(session?.annotations.canPlanPortal(at: position, in: dimension) != true)
    }
}
