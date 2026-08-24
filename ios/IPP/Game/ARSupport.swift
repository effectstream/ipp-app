import ARKit
import AVFoundation
import Foundation

/// Capability and camera-permission gate for the "Tiro al Trofeo" AR mini-game.
///
/// Nothing here starts a camera on its own:
/// - `isWorldTrackingSupported` and `cameraPermission` only *read* state iOS
///   already knows, so they are safe to call from the leaderboard while
///   deciding whether to show the entry point.
/// - `requestCameraAccess()` is the only call that can raise the system prompt,
///   and it is invoked exclusively from `TrophyTossView` — i.e. when the player
///   opens the game, never at app launch (FR-010).
///
/// This type is offline by construction: it performs no networking (FR-008).
enum ARSupport {

    // MARK: - Device capability

    /// `true` when the device can run ARKit world tracking.
    ///
    /// Returns `false` in the iOS Simulator and on hardware without
    /// world-tracking support, which is what hides/disables the game entry
    /// point (FR-001).
    static var isWorldTrackingSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    /// Short Spanish explanation shown next to the disabled entry point.
    static var unsupportedMessage: String {
        #if targetEnvironment(simulator)
        return "El mini-juego usa la cámara: solo funciona en un iPhone real."
        #else
        return "Este iPhone no admite el seguimiento de realidad aumentada."
        #endif
    }

    // MARK: - Camera permission

    /// The camera answer the player has already given, if any.
    enum CameraPermission: Equatable {
        /// The player has not been asked yet — asking is up to the game view.
        case notDetermined
        case granted
        case denied
        /// Blocked by the device itself (parental controls, MDM profile).
        case restricted
    }

    /// Current camera authorization, read without touching the camera.
    static var cameraPermission: CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Raises the system camera prompt when the answer is still
    /// `.notDetermined`, and reports the resulting permission.
    ///
    /// Call this **only** when the game view appears (FR-010).
    @discardableResult
    static func requestCameraAccess() async -> CameraPermission {
        guard cameraPermission == .notDetermined else { return cameraPermission }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return cameraPermission
    }
}
