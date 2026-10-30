import Foundation
import SwiftUI

/// One document sheet, including its draft or demand on the shared world snapshot.
enum WorldSheet: Identifiable {
    case coordinates
    case imageExport
    case blockFilter
    case savedPlace(SavedPlaceDraft)
    case portal(PortalPlanDraft)
    case statistics(PlayerRecordStore.Handle)

    enum ID: Hashable {
        case coordinates, imageExport, blockFilter
        case savedPlace(UUID), portal(UUID), statistics(ObjectIdentifier)
    }

    var id: ID {
        switch self {
        case .coordinates: .coordinates
        case .imageExport: .imageExport
        case .blockFilter: .blockFilter
        case .savedPlace(let draft): .savedPlace(draft.id)
        case .portal(let draft): .portal(draft.id)
        case .statistics(let records): .statistics(ObjectIdentifier(records))
        }
    }

    var savedPlaceDraft: SavedPlaceDraft? {
        guard case .savedPlace(let draft) = self else { return nil }
        return draft
    }

    var portalDraft: PortalPlanDraft? {
        guard case .portal(let draft) = self else { return nil }
        return draft
    }

    var playerRecords: PlayerRecordStore.Handle? {
        guard case .statistics(let records) = self else { return nil }
        return records
    }
}

struct WorldSheetView: View {
    let session: WorldSession
    let sheet: WorldSheet

    var body: some View {
        switch sheet {
        case .coordinates:
            GoToCoordinatesView(session: session)
        case .imageExport:
            MapExportView(session: session)
        case .blockFilter:
            if let map = session.map { MapBlockFilterView(session: session, map: map) }
        case .savedPlace(let draft):
            SavedPlaceEditor(session: session, draft: draft)
        case .portal(let draft):
            PortalPlanView(session: session, draft: draft)
        case .statistics(let records):
            StatisticsTable(rows: records.records?.rows ?? [])
        }
    }
}
