import ARKit
import Combine
import RealityKit
import SwiftUI
import UIKit

/// Shared state between the RealityKit `ARView` and the SwiftUI overlay drawn
/// on top of it.
///
/// The view reads the published values to decide what hint and which buttons to
/// show; `relocate()` is the one command that travels the other way, into the
/// coordinator that owns the AR session.
@MainActor
final class PodiumARModel: ObservableObject {

    /// What the session is doing right now, most severe first when it comes to
    /// choosing a hint.
    enum Phase: Equatable {
        /// Looking for a horizontal plane — the coaching overlay is up.
        case scanning
        /// A plane exists; the player can tap to place the podium.
        case readyToPlace
        /// The podium is anchored in the world.
        case placed
    }

    @Published fileprivate(set) var phase: Phase = .scanning
    /// Set while ARKit reports limited tracking or an interruption. The podium
    /// keeps its anchor throughout — this only drives the hint (FR-002).
    @Published fileprivate(set) var trackingIssue: String?
    /// Unrecoverable session error; the player has to close and reopen.
    @Published fileprivate(set) var failure: String?
    /// Short-lived feedback, e.g. a tap that hit no surface.
    @Published fileprivate(set) var transientHint: String?

    /// Installed by the coordinator so the overlay's "Reubicar" button can
    /// reach the AR session.
    fileprivate var relocateHandler: (() -> Void)?

    var isPlaced: Bool { phase == .placed }

    /// The single line of Spanish shown at the bottom of the AR view.
    var hint: String {
        if let failure { return failure }
        if let trackingIssue { return trackingIssue }
        if let transientHint { return transientHint }
        switch phase {
        case .scanning:
            return "Mueve el teléfono para detectar una superficie."
        case .readyToPlace:
            return "Toca la superficie para colocar el podio."
        case .placed:
            return "Podio colocado. Lanza pelotas o pulsa Reubicar."
        }
    }

    /// Drops the placed podium and goes back to scanning so the player can pick
    /// a new spot. Phase 4 will additionally forbid this mid-round.
    func relocate() {
        relocateHandler?()
    }

    fileprivate func flash(_ message: String) {
        transientHint = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.transientHint == message else { return }
            self.transientHint = nil
        }
    }
}

/// The AR half of "Tiro al Trofeo": a RealityKit `ARView` running world
/// tracking with horizontal plane detection, an `ARCoachingOverlayView` for the
/// scan hint, and tap-to-place for the procedural podium (FR-002, FR-003).
///
/// The session is torn down completely when SwiftUI removes the view — paused,
/// un-delegated, anchors and subscriptions dropped — so closing the game leaves
/// nothing running behind the leaderboard (FR-011).
///
/// Offline by construction: nothing here performs any networking (FR-008).
struct PodiumARViewContainer: UIViewRepresentable {

    @ObservedObject var model: PodiumARModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> ARView {
        #if DEBUG
        let problems = PodiumBuilder.selfCheck()
        assert(problems.isEmpty, "PodiumBuilder produced a broken scene: \(problems)")
        #endif

        let arView = ARView(frame: .zero)
        // Our configuration, not ARView's guess.
        arView.automaticallyConfigureSession = false
        arView.session.delegate = context.coordinator
        // Delegate callbacks land on the main queue, which is where the
        // published state and the RealityKit scene both live.
        arView.session.delegateQueue = .main

        context.coordinator.attach(to: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // All state flows out of the coordinator; nothing to push back in.
    }

    /// Full teardown when the game screen goes away (FR-011).
    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate, ARCoachingOverlayViewDelegate {

        private let model: PodiumARModel
        private weak var arView: ARView?
        private let coachingOverlay = ARCoachingOverlayView()
        private var tapRecognizer: UITapGestureRecognizer?

        /// The one anchor the podium lives on. Kept so relocation can remove
        /// exactly it, and so tracking recovery can be checked against it.
        private var podiumAnchor: AnchorEntity?
        /// Phase 3 will put its collision subscriptions here; the array exists
        /// now so teardown is already correct.
        private var subscriptions: [any Cancellable] = []
        private var lifecycleObservers: [NSObjectProtocol] = []

        private var hasSeenPlane = false
        private var isPausedForBackground = false
        private var isTornDown = false

        init(model: PodiumARModel) {
            self.model = model
            super.init()
            model.relocateHandler = { [weak self] in self?.relocate() }
        }

        // MARK: Session configuration

        /// World tracking with horizontal plane detection — the minimum the
        /// game needs, and nothing more (no people occlusion, no scene mesh),
        /// which keeps the frame rate healthy on older iPhones.
        private func makeConfiguration() -> ARWorldTrackingConfiguration {
            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = [.horizontal]
            configuration.environmentTexturing = .automatic
            configuration.isLightEstimationEnabled = true
            return configuration
        }

        func attach(to arView: ARView) {
            self.arView = arView

            arView.session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])

            installCoachingOverlay(on: arView)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            arView.addGestureRecognizer(tap)
            tapRecognizer = tap

            observeAppLifecycle()
        }

        private func installCoachingOverlay(on arView: ARView) {
            coachingOverlay.session = arView.session
            coachingOverlay.goal = .horizontalPlane
            coachingOverlay.activatesAutomatically = true
            coachingOverlay.delegate = self
            coachingOverlay.translatesAutoresizingMaskIntoConstraints = false
            arView.addSubview(coachingOverlay)
            NSLayoutConstraint.activate([
                coachingOverlay.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
                coachingOverlay.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
                coachingOverlay.topAnchor.constraint(equalTo: arView.topAnchor),
                coachingOverlay.bottomAnchor.constraint(equalTo: arView.bottomAnchor)
            ])
        }

        // MARK: App lifecycle
        //
        // Backgrounding stops the camera. We pause explicitly on the way out
        // and re-run the *same* configuration with no options on the way back
        // in — no `.resetTracking`, no `.removeExistingAnchors`, so the podium
        // keeps the anchor it was placed on and ARKit relocalises to it
        // instead of the podium jumping somewhere new.

        private func observeAppLifecycle() {
            let center = NotificationCenter.default
            lifecycleObservers.append(
                center.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pauseForBackground() }
                }
            )
            lifecycleObservers.append(
                center.addObserver(
                    forName: UIApplication.willEnterForegroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resumeFromBackground() }
                }
            )
        }

        private func pauseForBackground() {
            guard !isTornDown, !isPausedForBackground else { return }
            isPausedForBackground = true
            arView?.session.pause()
        }

        private func resumeFromBackground() {
            guard !isTornDown, isPausedForBackground else { return }
            isPausedForBackground = false
            // No options: existing anchors survive, tracking relocalises.
            arView?.session.run(makeConfiguration())
            model.trackingIssue = nil
        }

        // MARK: Placement

        @objc
        private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView, podiumAnchor == nil else { return }

            let point = gesture.location(in: arView)
            // Prefer a real detected plane; fall back to ARKit's estimate so a
            // confident player is not blocked by a slow plane extension.
            let hit = arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first
                ?? arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first

            guard let hit else {
                model.flash("Ahí no vemos superficie. Prueba en otro punto de la mesa o el suelo.")
                return
            }

            place(at: hit.worldTransform, in: arView)
        }

        private func place(at worldTransform: simd_float4x4, in arView: ARView) {
            let position = SIMD3<Float>(
                worldTransform.columns.3.x,
                worldTransform.columns.3.y,
                worldTransform.columns.3.z
            )

            // Anchor on the world position only — the raycast's own rotation
            // follows the plane's arbitrary axes, which would spin the podium.
            let anchor = AnchorEntity(world: position)
            let scene = PodiumBuilder.makeScene()
            scene.orientation = simd_quatf(angle: yaw(towardCameraFrom: position, in: arView), axis: [0, 1, 0])
            anchor.addChild(scene)
            arView.scene.addAnchor(anchor)

            podiumAnchor = anchor
            model.phase = .placed
            model.transientHint = nil

            // From here the player is looking at the podium, so stop the
            // full-screen coaching overlay from covering it; our own hint takes
            // over if tracking degrades.
            coachingOverlay.activatesAutomatically = false
            coachingOverlay.setActive(false, animated: true)
        }

        /// Rotation about +Y that turns the podium's front (+Z) toward the
        /// camera, so the steps face the player however they were standing.
        private func yaw(towardCameraFrom position: SIMD3<Float>, in arView: ARView) -> Float {
            guard let frame = arView.session.currentFrame else { return 0 }
            let camera = frame.camera.transform.columns.3
            let dx = camera.x - position.x
            let dz = camera.z - position.z
            guard dx * dx + dz * dz > 1e-6 else { return 0 }
            return atan2(dx, dz)
        }

        private func relocate() {
            guard !isTornDown, let arView, let anchor = podiumAnchor else { return }
            arView.scene.removeAnchor(anchor)
            podiumAnchor = nil
            model.phase = hasSeenPlane ? .readyToPlace : .scanning
            model.transientHint = nil
            coachingOverlay.activatesAutomatically = true
        }

        // MARK: ARSessionDelegate / ARCoachingOverlayViewDelegate
        //
        // The delegate methods themselves are `nonisolated` — ARKit's protocols
        // make no isolation promise, and claiming otherwise is a data race in
        // the Swift 6 language mode. Each one boils its payload down to a plain
        // value and hops to the main actor, where the model and the RealityKit
        // scene live.

        nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            guard anchors.contains(where: { $0 is ARPlaneAnchor }) else { return }
            Task { @MainActor in self.planeBecameAvailable() }
        }

        nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            let issue = Self.message(for: camera.trackingState)
            Task { @MainActor in self.model.trackingIssue = issue }
        }

        nonisolated func sessionWasInterrupted(_ session: ARSession) {
            Task { @MainActor in
                self.model.trackingIssue = "Sesión en pausa. Vuelve a apuntar a la superficie."
            }
        }

        nonisolated func sessionInterruptionEnded(_ session: ARSession) {
            // Deliberately no `run(_:options:)` here: ARKit resumes on its own
            // and relocalises to the existing anchor. Resetting would move the
            // podium, which the spec forbids.
            Task { @MainActor in self.model.trackingIssue = nil }
        }

        nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
            let failure = Self.message(for: error)
            Task { @MainActor in self.model.failure = failure }
        }

        nonisolated func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) {
            Task { @MainActor in self.planeBecameAvailable() }
        }

        /// A horizontal plane exists, so the player can tap to place.
        private func planeBecameAvailable() {
            hasSeenPlane = true
            if model.phase == .scanning {
                model.phase = .readyToPlace
            }
        }

        // MARK: Hint copy

        nonisolated private static func message(for state: ARCamera.TrackingState) -> String? {
            switch state {
            case .normal:
                return nil
            case .notAvailable:
                return "Recupera la superficie: mueve el teléfono despacio."
            case .limited(.initializing):
                return "Preparando la cámara…"
            case .limited(.relocalizing):
                return "Recuperando la superficie: apunta al mismo sitio de antes."
            case .limited(.excessiveMotion):
                return "Mueve el teléfono más despacio."
            case .limited(.insufficientFeatures):
                return "Poca luz o superficie lisa: apunta a una zona con más detalle."
            case .limited:
                return "Recupera la superficie: mueve el teléfono despacio."
            }
        }

        nonisolated private static func message(for error: Error) -> String {
            guard let arError = error as? ARError else {
                return "La cámara falló. Cierra el juego y vuelve a abrirlo."
            }
            switch arError.code {
            case .cameraUnauthorized:
                return "Sin permiso de cámara. Actívalo en Ajustes › IPP › Cámara."
            case .sensorUnavailable, .sensorFailed:
                return "La cámara no está disponible ahora mismo."
            default:
                return "La sesión de realidad aumentada falló. Cierra el juego y vuelve a abrirlo."
            }
        }

        // MARK: Teardown (FR-011)

        func tearDown() {
            guard !isTornDown else { return }
            isTornDown = true

            model.relocateHandler = nil

            for observer in lifecycleObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            lifecycleObservers.removeAll()

            subscriptions.removeAll()

            coachingOverlay.delegate = nil
            coachingOverlay.session = nil
            coachingOverlay.removeFromSuperview()

            if let arView {
                if let tapRecognizer {
                    arView.removeGestureRecognizer(tapRecognizer)
                }
                arView.scene.anchors.removeAll()
                arView.session.pause()
                arView.session.delegate = nil
            }
            tapRecognizer = nil
            podiumAnchor = nil
            arView = nil
        }
    }
}
