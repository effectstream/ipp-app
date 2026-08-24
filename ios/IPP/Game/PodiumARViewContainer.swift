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
    /// Balls landed in the cup since the game screen opened. Phase 4 replaces
    /// this free-play counter with a per-round score (FR-007); for now it is the
    /// whole HUD.
    @Published fileprivate(set) var score: Int = 0

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
            return "Desliza hacia arriba para lanzar la pelota a la copa."
        }
    }

    /// Drops the placed podium and goes back to scanning so the player can pick
    /// a new spot. Phase 4 will additionally forbid this mid-round.
    func relocate() {
        relocateHandler?()
    }

    fileprivate func registerScore() {
        score += 1
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
/// scan hint, tap-to-place for the procedural podium (FR-002, FR-003) and
/// swipe-to-throw for the balls, including cup scoring and ball culling
/// (FR-004, FR-005, FR-006).
///
/// The rules of the throw live in `TossController`, which knows nothing about
/// ARKit; this file supplies the camera pose, the entities and the frame clock.
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
        private var panRecognizer: UIPanGestureRecognizer?

        /// The one anchor the podium lives on. Kept so relocation can remove
        /// exactly it, and so tracking recovery can be checked against it.
        private var podiumAnchor: AnchorEntity?
        private var subscriptions: [any Cancellable] = []
        /// Cup-trigger subscription, held apart from the rest because it is made
        /// and dropped with the podium rather than with the view.
        private var cupSubscription: (any Cancellable)?
        private var lifecycleObservers: [NSObjectProtocol] = []

        private var hasSeenPlane = false
        private var isPausedForBackground = false
        private var isTornDown = false

        // MARK: Toss state (Phase 3)

        /// Rules and tuning for the toss — pure, and unit-tested off-device.
        private var toss = TossController()
        /// Balls currently in the scene, with the bookkeeping the culler needs.
        private var balls: [LiveBall] = []
        /// When the current swipe started, in `CACurrentMediaTime()` seconds.
        private var swipeStart: TimeInterval?
        /// The trophy's resting transform, captured at placement so the score
        /// pulse always animates back to a known pose rather than to whatever
        /// mid-animation value it happens to read.
        private var trophyRestTransform: Transform?
        private let successHaptics = UINotificationFeedbackGenerator()

        /// One ball in flight: the entity plus the two timers the culling rules
        /// in `TossController` are written against (FR-006).
        private struct LiveBall {
            let id: TossController.BallID
            let entity: ModelEntity
            var age: TimeInterval = 0
            var restingFor: TimeInterval = 0
        }

        init(model: PodiumARModel) {
            self.model = model
            super.init()
            model.relocateHandler = { [weak self] in self?.relocate() }
        }

        // MARK: Session configuration

        /// World tracking with horizontal plane detection, plus person
        /// occlusion where the hardware offers it. No scene mesh — the podium
        /// only ever sits on a detected plane, so reconstruction would cost
        /// frame rate for nothing.
        ///
        /// Person occlusion comes from Gate 2's one finding (row 2.4): with it
        /// off, a hand passing in front of the phone is painted *behind* the
        /// podium, which reads as broken. `.personSegmentationWithDepth` makes
        /// people and hands occlude virtual content at the right depth. It needs
        /// an A12 or newer device, so the capability is checked and the game
        /// simply runs without it on older hardware.
        private func makeConfiguration() -> ARWorldTrackingConfiguration {
            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = [.horizontal]
            configuration.environmentTexturing = .automatic
            configuration.isLightEstimationEnabled = true
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                configuration.frameSemantics.insert(.personSegmentationWithDepth)
            }
            return configuration
        }

        func attach(to arView: ARView) {
            self.arView = arView

            arView.session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])

            installCoachingOverlay(on: arView)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            arView.addGestureRecognizer(tap)
            tapRecognizer = tap

            // Tap places the podium, swipe throws a ball. The two never fight:
            // a pan only begins once the finger has moved, which a tap never
            // does, and the swipe handler ignores everything until the podium
            // is down.
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            arView.addGestureRecognizer(pan)
            panRecognizer = pan

            subscriptions.append(
                arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                    MainActor.assumeIsolated { self?.stepBalls(deltaTime: event.deltaTime) }
                }
            )

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

            trophyRestTransform = scene.findEntity(named: PodiumBuilder.Name.trophy)?.transform
            subscribeToCup(in: arView, anchor: anchor)
            // Warms the Taptic Engine so the first score's haptic is immediate.
            successHaptics.prepare()

            // From here the player is looking at the podium, so stop the
            // full-screen coaching overlay from covering it; our own hint takes
            // over if tracking degrades.
            coachingOverlay.activatesAutomatically = false
            coachingOverlay.setActive(false, animated: true)
        }

        /// Listens to the cup's invisible trigger volume, which is the only
        /// thing that can turn a ball into a point (FR-005).
        private func subscribeToCup(in arView: ARView, anchor: AnchorEntity) {
            cupSubscription = nil
            guard let trigger = anchor.findEntity(named: PodiumBuilder.Name.cupTrigger) else { return }
            cupSubscription = arView.scene.subscribe(
                to: CollisionEvents.Began.self,
                on: trigger
            ) { [weak self] event in
                MainActor.assumeIsolated { self?.handleCupEntry(event) }
            }
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
            // The balls are children of this anchor, so removing it takes them
            // with it; the controller has to be told so its live-ball cap does
            // not stay pinned at the balls that no longer exist.
            balls.removeAll()
            toss.retireAll()
            cupSubscription = nil
            trophyRestTransform = nil
            arView.scene.removeAnchor(anchor)
            podiumAnchor = nil
            model.phase = hasSeenPlane ? .readyToPlace : .scanning
            model.transientHint = nil
            coachingOverlay.activatesAutomatically = true
        }

        // MARK: - Tossing (FR-004)

        /// A swipe anywhere on the AR view throws a ball. Power comes from how
        /// fast the finger travelled *upward*, aim from where the phone points,
        /// and a nudge left or right from the swipe's horizontal component —
        /// all of it decided by `TossController`, which this method only feeds
        /// and obeys.
        @objc
        private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard !isTornDown, let arView, podiumAnchor != nil else { return }

            switch gesture.state {
            case .began:
                swipeStart = CACurrentMediaTime()
            case .ended:
                let now = CACurrentMediaTime()
                let started = swipeStart ?? now
                swipeStart = nil
                let translation = gesture.translation(in: arView)
                throwBall(
                    TossController.Swipe(
                        translation: SIMD2(Float(translation.x), Float(translation.y)),
                        duration: now - started
                    ),
                    at: now
                )
            case .cancelled, .failed:
                swipeStart = nil
            default:
                break
            }
        }

        private func throwBall(_ swipe: TossController.Swipe, at now: TimeInterval) {
            guard let arView,
                  let anchor = podiumAnchor,
                  let frame = arView.session.currentFrame
            else { return }

            let camera = TossController.CameraBasis(transform: frame.camera.transform)

            switch toss.flick(swipe, camera: camera, at: now) {
            case .rejected(.tooManyLiveBalls):
                model.flash("Demasiadas pelotas en juego. Espera un momento.")
            case .rejected:
                // A drag that was not a toss, or a flick inside the 0.3 s rate
                // limit. Both are the player's normal behaviour, not errors, so
                // they pass in silence.
                break
            case .launched(let launch):
                spawn(launch, on: anchor)
            }
        }

        /// Puts one ball into the scene and pushes it.
        ///
        /// The ball is parented to the **podium's own anchor** rather than to a
        /// new one: RealityKit simulates physics per anchor, so a ball on any
        /// other anchor would fall straight through the steps, the cup and the
        /// floor plane.
        private func spawn(_ launch: TossController.Launch, on anchor: AnchorEntity) {
            let ball = PodiumBuilder.makeBall(
                id: launch.ball,
                radius: toss.tuning.ballRadius,
                mass: toss.tuning.ballMass,
                friction: toss.tuning.ballFriction,
                restitution: toss.tuning.ballRestitution
            )
            anchor.addChild(ball)
            // The launch is computed in world space; the ball's transform is
            // relative to the anchor it now hangs from.
            ball.position = anchor.convert(position: launch.origin, from: nil)
            ball.applyLinearImpulse(launch.impulse, relativeTo: nil)
            balls.append(LiveBall(id: launch.ball, entity: ball))
        }

        // MARK: - Scoring (FR-005, SC-002)

        private func handleCupEntry(_ event: CollisionEvents.Began) {
            guard !isTornDown else { return }
            // One of the two entities is the trigger volume; the other is
            // whatever crossed it. Only a ball we launched counts.
            guard let ball = balls.first(where: { $0.entity === event.entityA || $0.entity === event.entityB })
            else { return }
            // False unless this is the ball's *first* crossing, so a ball that
            // settles, rolls and re-triggers still scores exactly once.
            guard toss.score(ball.id) else { return }

            model.registerScore()
            celebrate()
        }

        /// Success cue: the success haptic plus a quick swell of the trophy, so
        /// the score reads even when the phone is at arm's length.
        private func celebrate() {
            successHaptics.notificationOccurred(.success)
            successHaptics.prepare()

            guard let trophy = podiumAnchor?.findEntity(named: PodiumBuilder.Name.trophy),
                  let rest = trophyRestTransform
            else { return }

            var swollen = rest
            swollen.scale = rest.scale * 1.28
            _ = trophy.move(to: swollen, relativeTo: trophy.parent, duration: 0.14, timingFunction: .easeOut)

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, !self.isTornDown, let rest = self.trophyRestTransform else { return }
                _ = trophy.move(to: rest, relativeTo: trophy.parent, duration: 0.22, timingFunction: .easeInOut)
            }
        }

        // MARK: - Culling (FR-006, SC-006)

        /// Runs once per rendered frame: ages every live ball, tracks how long
        /// it has been still, and removes it once `TossController` says it is
        /// litter — at rest, off the table, or simply too old. This is what
        /// keeps a minute of spam-flicking bounded (SC-006).
        private func stepBalls(deltaTime: TimeInterval) {
            guard !isTornDown, !balls.isEmpty, let anchor = podiumAnchor else { return }

            var survivors: [LiveBall] = []
            survivors.reserveCapacity(balls.count)

            for var ball in balls {
                ball.age += deltaTime
                let speed = simd_length(ball.entity.physicsMotion?.linearVelocity ?? .zero)
                ball.restingFor = toss.restingDuration(
                    previous: ball.restingFor,
                    speed: speed,
                    delta: deltaTime
                )
                let height = ball.entity.position(relativeTo: anchor).y

                if toss.cullReason(
                    age: ball.age,
                    restingFor: ball.restingFor,
                    heightAboveAnchor: height
                ) != nil {
                    ball.entity.removeFromParent()
                    toss.retire(ball.id)
                } else {
                    survivors.append(ball)
                }
            }

            balls = survivors
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
            cupSubscription = nil

            balls.removeAll()
            toss.retireAll()
            trophyRestTransform = nil
            swipeStart = nil

            coachingOverlay.delegate = nil
            coachingOverlay.session = nil
            coachingOverlay.removeFromSuperview()

            if let arView {
                if let tapRecognizer {
                    arView.removeGestureRecognizer(tapRecognizer)
                }
                if let panRecognizer {
                    arView.removeGestureRecognizer(panRecognizer)
                }
                arView.scene.anchors.removeAll()
                arView.session.pause()
                arView.session.delegate = nil
            }
            tapRecognizer = nil
            panRecognizer = nil
            podiumAnchor = nil
            arView = nil
        }
    }
}
