import AppKit
import Foundation

/// Temporary diagnostic only. Records existing writes without another view dependency or state owner.
enum InspectorBindingTrace {
    private struct Entry: Encodable {
        let event: String
        let session: String?
        let selection: String?
        let viewID: String?
        let dimension: String?
        let requested: Bool?
        let appearsActive: Bool?
        let shown: Bool?
        let storageSelected: Bool?
        let commandAvailable: Bool
        let sessionClosed: Bool?
        let sheetPresented: Bool?
        let frontDimension: Bool?
        let applicationActive: Bool?
        let keyWindow: Int?
        let mainWindow: Int?
    }

    static func record(_ event: String, session: WorldSession?, requested: Bool? = nil,
                       appearsActive: Bool? = nil) {
        let entry = Entry(event: event,
                          session: session.map { String(describing: ObjectIdentifier($0)) },
                          selection: session.map { String(describing: ObjectIdentifier($0.selection)) },
                          viewID: session?.viewID.uuidString,
                          dimension: session?.selectedDimensionID,
                          requested: requested, appearsActive: appearsActive,
                          shown: session?.selection.isInspectorShown,
                          storageSelected: session.map { $0.selection.sidebarSelection == .storage },
                          commandAvailable: session?.commandTarget != nil,
                          sessionClosed: session?.isClosed,
                          sheetPresented: session.map { $0.sheet != nil },
                          frontDimension: session.map { $0.resources.activeDimensionID == $0.selectedDimensionID },
                          applicationActive: NSApp?.isActive,
                          keyWindow: NSApp?.keyWindow?.windowNumber,
                          mainWindow: NSApp?.mainWindow?.windowNumber)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload: Data
        do { payload = try encoder.encode(entry) }
        catch { payload = Data("{\"event\":\"encoding-failed\"}".utf8) }
        // The selected native test already captures stdout. A separate prefix leaves its event parser unchanged.
        FileHandle.standardOutput.write(Data("Inspector binding trace: ".utf8) + payload + Data([10]))
    }
}
