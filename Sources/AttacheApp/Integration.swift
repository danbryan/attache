import Foundation

/// Health of a configured integration, determined by a real request to its
/// endpoint (not merely whether a key was typed).
enum IntegrationHealth: Equatable {
    case unconfigured
    case checking
    case healthy
    case unhealthy(String)
}
