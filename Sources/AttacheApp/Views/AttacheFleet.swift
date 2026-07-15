import AttacheCore
import SwiftUI

/// Which sessions render individually and which merge into count badges
/// (INF-275, ring form INF-280). Pure and unit-tested; the motor layers ring
/// positions and motion on top of this decision.
///
/// Rules, in order:
/// - Blocked (needs-you) and finished sessions are always individual; they
///   carry glyphs and need eyes and a click target.
/// - The focused session is always individual, whatever its state.
/// - Working sessions running sub-agents stay individual (they ripple), up
///   to two per agent; beyond that they join the badge and the badge does
///   the rippling implicitly.
/// - Remaining working sessions show individually up to the cap, otherwise
///   they all merge into one orbiting count badge.
/// - Quiet sessions show individually up to the cap, otherwise they merge
///   into one parked, dimmed count badge. A focused-quiet session stays out
///   front regardless.
struct AttacheFleetLayout: Equatable {
    struct AgentGroup: Equatable {
        var orbiting: [AttacheFleetSession] = []
        var orbitingBadgeCount = 0
        var parked: [AttacheFleetSession] = []
        var parkedBadgeCount = 0
        var blocked: [AttacheFleetSession] = []
        var finished: [AttacheFleetSession] = []

        var isEmpty: Bool {
            orbiting.isEmpty && orbitingBadgeCount == 0 && parked.isEmpty
                && parkedBadgeCount == 0 && blocked.isEmpty && finished.isEmpty
        }
    }

    static let individualCap = 4
    static let ripplerCap = 2

    var groups: [AttacheAgentIdentity: AgentGroup] = [:]

    static func compute(fleet: [AttacheFleetSession]) -> AttacheFleetLayout {
        var layout = AttacheFleetLayout()
        for agent in AttacheAgentIdentity.allCases {
            let members = fleet.filter { $0.agent == agent }
            guard !members.isEmpty else { continue }
            var group = AgentGroup()

            group.blocked = members.filter { $0.state == .blocked }
            group.finished = members.filter { $0.state == .finished }

            let working = members.filter { $0.state == .working }
            let focusedWorking = working.filter(\.isFocused)
            let ripplers = working.filter { !$0.isFocused && $0.activeSubAgents > 0 }
            let plain = working.filter { !$0.isFocused && $0.activeSubAgents == 0 }
            let shownRipplers = Array(ripplers.prefix(ripplerCap))
            let overflowRipplers = ripplers.count - shownRipplers.count
            var orbiting = focusedWorking + shownRipplers
            let plainSlots = max(0, individualCap - orbiting.count)
            if plain.count <= plainSlots && overflowRipplers == 0 {
                orbiting += plain
            } else {
                group.orbitingBadgeCount = plain.count + overflowRipplers
            }
            group.orbiting = orbiting

            let quiet = members.filter { $0.state == .quiet }
            let plainQuiet = quiet.filter { !$0.isFocused }
            if plainQuiet.count <= individualCap {
                // Fleet order, not focused-first: a focus change must move
                // the ring, never shuffle motes between slots.
                group.parked = quiet
            } else {
                group.parked = quiet.filter(\.isFocused)
                group.parkedBadgeCount = plainQuiet.count
            }

            if !group.isEmpty {
                layout.groups[agent] = group
            }
        }
        return layout
    }
}

/// One drawable fleet element, positioned in the mark's design units by the
/// motor. The figure renders exactly what it is given.
struct AttacheFleetMote: Equatable {
    enum Fill: Equatable {
        case agent(AttacheAgentIdentity)
        case blocked
        case focused
    }

    /// The state glyph inside the mote (INF-280): ? for needs-you, a check
    /// for a completed turn. Badges carry counts instead.
    enum Glyph: Equatable {
        case none
        case question
        case check
    }

    var position: CGPoint
    var radius: CGFloat = 3.6
    var fill: Fill
    var opacity: Double = 1
    /// The focused session's halo.
    var ring = false
    /// Badge numeral; nil for a plain mote.
    var count: Int?
    /// Sub-agent ripple ring radii as fractions 0-1 of the full ripple.
    var ripples: [Double] = []
    /// Hit-testing: a session id for plain motes, nil for badges.
    var sessionID: String?
    /// Hover affordance text (session title, or a badge summary).
    var title = ""
    /// True on the far half of the ring: the figure draws these behind the
    /// head and arcs so the orbit reads as passing around the character.
    var behind = false
    var glyph: Glyph = .none
    /// True only for the focused mote, which the user may drag along the
    /// ring; the view's drag gesture checks this flag.
    var draggable = false
}
