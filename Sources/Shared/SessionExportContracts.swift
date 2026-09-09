import Foundation

// Contracts shared between the iPhone app and the Mac console (ADR-014 D7).
//
// The session readback layer takes these two dependencies so it can be handed a
// destination that the platform resolved for it. The iPhone resolves a
// security-scoped bookmark the user picked in Files; the Mac already knows the
// folder from the companion's own heartbeat and needs no scope at all. Only the
// declarations live here — each platform keeps its own implementation.

protocol SessionExportDestinationStoring: Sendable {
    func load() throws -> SessionExportDestinationState
    func save(_ destination: SessionExportDestination) throws
    func clear() throws
}

enum SessionExportDestinationState: Equatable, Sendable {
    case missing
    case stale(displayName: String)
    case available(SessionExportDestination)
}

struct SessionExportDestination: Equatable, Sendable {
    let rootURL: URL
    let displayName: String

    init(rootURL: URL, displayName: String) {
        self.rootURL = rootURL
        self.displayName = displayName
    }
}

protocol SessionExportSecurityScopeAccessing: Sendable {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// Security-scoped access is the iPhone's concern — the Mac reads a folder the
/// companion already told it about — but the API exists on both platforms and
/// is a harmless no-op where no scope was ever claimed, so the default
/// implementation is shared rather than duplicated.
final class AppleSessionExportSecurityScopeAccessor: SessionExportSecurityScopeAccessing, @unchecked Sendable {
    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
