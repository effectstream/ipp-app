import ARKit
import Combine
import RealityKit
import SwiftUI
import UIKit

/// Shared state between the RealityKit `ARView` and the SwiftUI overlay drawn
/// on top of it.
///
/// The view reads the published values to decide what hint, HUD and buttons to
/// show and calls the round controls; `relocate()` is the one command that
/// travels the other way, into the coordinator that owns the AR session.
///
/// The round itself is a `GameRound` value — every rule about time, pausing and
/// what counts lives there, tested off-device; this class only decides *when*
/// to poke it and republishes the result for SwiftUI (FR-007).
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

    // MARK: Round state (FR-007, FR-008)

    /// The timed round. `private(set)` because every mutation has to go through
    /// one of the methods below, which keep the persisted best score in step.
    @Published private(set) var round = GameRound()
    /// Balls landed in the cup outside a round. Free practice, reset whenever
    /// the game returns to `idle` — never mixed into a round's score.
    @Published private(set) var practiceScore: Int = 0
    /// Best round ever played on this device (FR-008). Read once at init and
    /// kept in step by ``finishRound()``.
    @Published private(set) var bestScore: Int
    /// Whether the round that just ended set a new best, so the summary can say
    /// so. Meaningless unless `round.hasEnded`.
    @Published private(set) var didSetRecord = false

    /// The game's only persistence.
    private let bestScores: BestScoreStore

    /// Installed by the coordinator so the overlay's "Reubicar" button can
    /// reach the AR session.
    fileprivate var relocateHandler: (() -> Void)?

    init(bestScores: BestScoreStore = BestScoreStore(), rules: GameRound.Rules = GameRound.Rules()) {
        self.bestScores = bestScores
        self.bestScore = bestScores.best
        self.round = GameRound(rules: rules)
    }

    var isPlaced: Bool { phase == .placed }

    /// What the score pill shows: the round's score once a round is under way
    /// or finished, the free-practice tally before that.
    var displayedScore: Int { round.isIdle ? practiceScore : round.score }

    /// "Comenzar" is only offered once there is something to throw at.
    var canStartRound: Bool { isPlaced && round.canStart }

    /// Relocating mid-round would move the target out from under a running
    /// clock, so the button is off while a round is on (anticipated by the
    /// Phase 2 task list).
    var canRelocate: Bool { isPlaced && !round.isRunning }

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
            return "Desliza hacia arriba para lanzar la pelota adentro de la copa."
        }
    }

    // MARK: Round controls

    /// "Comenzar" / "Jugar de nuevo".
    func startRound() {
        guard canStartRound else { return }
        didSetRecord = false
        practiceScore = 0
        round.start()
    }

    /// Dismissing the summary: back to free practice with a clean slate.
    func returnToPractice() {
        round.reset()
        practiceScore = 0
        didSetRecord = false
    }

    /// Stops or restarts the round clock. Called from the tracking-state
    /// delegate and from the view's `scenePhase` observer; both fire
    /// unconditionally, and `GameRound` makes that idempotent.
    func setPaused(_ paused: Bool, reason: GameRound.PauseReason) {
        round.setPaused(paused, reason: reason)
    }

    /// Drops the placed podium and goes back to scanning so the player can pick
    /// a new spot. Refused while a round is running.
    func relocate() {
        guard canRelocate else { return }
        returnToPractice()
        relocateHandler?()
    }

    /// One frame of round time, driven by the RealityKit update loop.
    fileprivate func tick(_ delta: TimeInterval) {
        if round.tick(delta) { finishRound() }
    }

    /// The clock hit zero: freeze the score and update the stored best.
    private func finishRound() {
        guard let score = round.finalScore else { return }
        didSetRecord = bestScores.submit(score)
        bestScore = bestScores.best
    }

    /// A ball earned points — `TossController.Tuning.hitPoints` for touching
    /// the cup, the rest of `makePoints` for landing in it (FR-005, amended at
    /// Gate 4). They count for the round if one is running, and otherwise only
    /// for the free-practice tally (see `GameRound`).
    ///
    /// - Returns: `false` when the points counted for nothing — a ball already
    ///   in flight when the round paused — so the caller can skip the fanfare
    ///   for a point the player did not get.
    @discardableResult
    fileprivate func registerScore(_ points: Int) -> Bool {
        if round.registerScore(points) { return true }
        guard round.isIdle else { return false }
        practiceScore += points
        return true
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
/// The rules of the throw live in `TossController` and the rules of a round in
/// `GameRound`, neither of which knows anything about ARKit; this file supplies
/// the camera pose, the entities and the frame clock they run on.
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
        /// Collision subscription for the +1 tier, held apart from the rest
        /// because it is made and dropped with the podium rather than with the
        /// view.
        private var contactSubscription: (any Cancellable)?
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
        private let successHaptics = UINotificationFeedbackGenerator()
        /// The lighter cue for the +1 tier, so a graze off the cup does not
        /// feel like a made shot (FR-005).
        private let hitHaptics = UIImpactFeedbackGenerator(style: .light)

        /// The cup, cached at placement so the cup rules can measure a ball's
        /// position in the cup's own frame without walking the hierarchy every
        /// frame.
        private weak var cupEntity: Entity?
        /// The trophy, cached at placement. The difficulty ramp animates it
        /// between steps inside its own parent, the steps container (US3).
        private weak var trophyEntity: Entity?
        /// Which step the cup is standing on right now.
        private var currentStep: PodiumBuilder.Step = .gold
        /// True from the moment a make is celebrated until the cup has finished
        /// sliding to its new step. Nothing scores in that window: the trophy
        /// is being scaled and moved, so every measurement taken in the cup's
        /// frame is in motion (US3, and it keeps the Gate 4 defect from coming
        /// back through the animation).
        private var isCupMoving = false
        /// Every collidable part of the cup, by identity. Touching any of them
        /// is the +1 tier (FR-005).
        private var cupContactIDs: Set<ObjectIdentifier> = []

        /// How long the cup takes to slide to its new step.
        private static let cupMoveDuration: TimeInterval = 0.4
        /// How long the trophy holds its celebratory swell before the move.
        private static let makeSwellDuration: TimeInterval = 0.14

        /// One ball in flight: the entity plus the timers the culling rules in
        /// `TossController` are written against (FR-006), how long it has been
        /// verifiably inside the cup (FR-005) and how many times it has been
        /// shoved off the cup's rim (Gate 3 row 3.2).
        private struct LiveBall {
            let id: TossController.BallID
            let entity: ModelEntity
            var age: TimeInterval = 0
            var restingFor: TimeInterval = 0
            var insideFor: TimeInterval = 0
            var rimNudges: Int = 0
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
                    MainActor.assumeIsolated { self?.step(deltaTime: event.deltaTime) }
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
            applyTrackingIssue(nil)
        }

        /// The one place tracking trouble is recorded: it drives both the hint
        /// line and the round clock, and those two must never disagree
        /// (FR-007, edge case "tracking loss mid-round").
        private func applyTrackingIssue(_ issue: String?) {
            model.trackingIssue = issue
            model.setPaused(issue != nil, reason: .trackingLimited)
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

            trophyEntity = scene.findEntity(named: PodiumBuilder.Name.trophy)
            cupEntity = scene.findEntity(named: PodiumBuilder.Name.cup)
            currentStep = .gold
            isCupMoving = false
            subscribeToCupContacts(in: arView, anchor: anchor)
            // Warms the Taptic Engine so the first score's haptic is immediate.
            successHaptics.prepare()
            hitHaptics.prepare()

            // From here the player is looking at the podium, so stop the
            // full-screen coaching overlay from covering it; our own hint takes
            // over if tracking degrades.
            coachingOverlay.activatesAutomatically = false
            coachingOverlay.setActive(false, animated: true)
        }

        /// Listens for balls touching the cup — the +1 tier (FR-005).
        ///
        /// One subscription for the whole scene rather than thirteen (twelve
        /// wall segments and the floor disc): the collidable parts of the cup
        /// are collected once, by identity, and every other contact in the
        /// scene — the table, the steps, ball against ball — is discarded with
        /// a set lookup.
        ///
        /// Note what this subscription is **not** used for: landing inside the
        /// cup. That is decided per frame from the ball's position, because a
        /// contact cannot tell which side of a 6 mm wall the ball is on — the
        /// Gate 4 defect in one sentence.
        private func subscribeToCupContacts(in arView: ARView, anchor: AnchorEntity) {
            contactSubscription = nil
            cupContactIDs = []
            guard let cup = anchor.findEntity(named: PodiumBuilder.Name.cup) else { return }

            var identifiers: Set<ObjectIdentifier> = []
            collectColliders(of: cup, into: &identifiers)
            cupContactIDs = identifiers

            contactSubscription = arView.scene.subscribe(to: CollisionEvents.Began.self) { [weak self] event in
                MainActor.assumeIsolated { self?.handleContact(event) }
            }
        }

        private func collectColliders(of entity: Entity, into identifiers: inout Set<ObjectIdentifier>) {
            if entity.components[CollisionComponent.self] != nil {
                identifiers.insert(ObjectIdentifier(entity))
            }
            for child in entity.children {
                collectColliders(of: child, into: &identifiers)
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
            contactSubscription = nil
            cupContactIDs = []
            trophyEntity = nil
            cupEntity = nil
            currentStep = .gold
            isCupMoving = false
            arView.scene.removeAnchor(anchor)
            podiumAnchor = nil
            model.phase = hasSeenPlane ? .readyToPlace : .scanning
            model.transientHint = nil
            coachingOverlay.activatesAutomatically = true
        }

        // MARK: - Tossing (FR-004)

        /// A swipe anywhere on the AR view throws a ball. Power comes from how
        /// fast the finger travelled *upward*, aim from where the phone points,
        /// a nudge left or right from the swipe's horizontal component, and —
        /// since Gate 4 — the ball's starting point from where the finger went
        /// down. All of it is decided by `TossController`, which this method
        /// only feeds and obeys.
        @objc
        private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard !isTornDown, let arView, podiumAnchor != nil else { return }
            // FR-007: no throwing while the round is paused or the summary is
            // up. Free practice before "Comenzar" is still allowed — see
            // `GameRound`'s doc comment for why.
            guard model.round.acceptsFlicks else {
                swipeStart = nil
                return
            }

            switch gesture.state {
            case .began:
                swipeStart = CACurrentMediaTime()
            case .ended:
                let now = CACurrentMediaTime()
                let started = swipeStart ?? now
                swipeStart = nil
                let translation = gesture.translation(in: arView)
                // Where the finger went *down*: a pan's translation is measured
                // from the touch-down point, so subtracting it from the current
                // location recovers that point exactly — better than the
                // location at `.began`, which UIKit only reports once the
                // finger has already slid a few points (FR-004).
                let current = gesture.location(in: arView)
                let start = CGPoint(x: current.x - translation.x, y: current.y - translation.y)
                throwBall(
                    TossController.Swipe(
                        translation: SIMD2(Float(translation.x), Float(translation.y)),
                        duration: now - started
                    ),
                    from: start,
                    at: now
                )
            case .cancelled, .failed:
                swipeStart = nil
            default:
                break
            }
        }

        private func throwBall(_ swipe: TossController.Swipe, from start: CGPoint, at now: TimeInterval) {
            guard let arView,
                  let anchor = podiumAnchor,
                  let frame = arView.session.currentFrame
            else { return }

            let camera = TossController.CameraBasis(transform: frame.camera.transform)
            // `ARView.ray(through:)` owns the projection matrix and the
            // interface orientation, so the touch point lands in the world
            // correctly without this file having to know either. A nil result
            // (no valid camera yet) falls back to the fixed spawn.
            let touch = arView.ray(through: start).map {
                TossController.TouchRay(origin: $0.origin, direction: $0.direction)
            }

            switch toss.flick(swipe, camera: camera, at: now, touch: touch) {
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

        /// A ball touched something. The +1 tier fires if that something was
        /// part of the cup.
        private func handleContact(_ event: CollisionEvents.Began) {
            guard !isTornDown, !cupContactIDs.isEmpty else { return }

            let hitCupWithA = cupContactIDs.contains(ObjectIdentifier(event.entityA))
            let hitCupWithB = cupContactIDs.contains(ObjectIdentifier(event.entityB))
            guard hitCupWithA != hitCupWithB else { return }
            let other = hitCupWithA ? event.entityB : event.entityA

            guard let ball = balls.first(where: { $0.entity === other }) else { return }
            creditHit(ball.id)
        }

        /// The +1 tier: this ball touched the cup, wherever on it.
        private func creditHit(_ ball: TossController.BallID) {
            guard !isCupMoving else { return }
            // nil unless this is the ball's *first* touch and it has not
            // already been paid the make, which is worth the full amount.
            guard let award = toss.registerHit(ball) else { return }
            // False when the points counted for nobody — the round is paused —
            // in which case there is nothing to acknowledge.
            guard model.registerScore(award.points) else { return }

            hitHaptics.impactOccurred(intensity: 0.55)
            hitHaptics.prepare()
            pulse(scale: 1.08, rise: 0.09, fall: 0.12)
        }

        /// The +10 tier: this ball is verifiably sitting in the cup.
        private func creditMake(_ ball: TossController.BallID) {
            guard !isCupMoving else { return }
            guard let award = toss.registerMake(ball) else { return }
            guard model.registerScore(award.points) else { return }

            celebrateMake()
        }

        /// Success cue: the success haptic and a big swell of the trophy, so
        /// the score reads even when the phone is at arm's length — followed by
        /// the cup jumping to another step (US3).
        ///
        /// Scoring is suspended for the whole sequence. The trophy is being
        /// scaled and then moved, so anything measured in the cup's frame
        /// meanwhile is measured against a target that is not where it looks.
        private func celebrateMake() {
            successHaptics.notificationOccurred(.success)
            successHaptics.prepare()

            isCupMoving = true
            guard let trophy = trophyEntity else {
                isCupMoving = false
                return
            }

            var swollen = trophyRestTransform
            swollen.scale = trophyRestTransform.scale * 1.28
            _ = trophy.move(
                to: swollen,
                relativeTo: trophy.parent,
                duration: Self.makeSwellDuration,
                timingFunction: .easeOut
            )

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.makeSwellDuration * 1_000_000_000) + 10_000_000)
                guard let self, !self.isTornDown else { return }
                self.relocateCup()
            }
        }

        // MARK: - Difficulty ramp (spec US3)

        /// Slides the cup to a different podium step, so the next toss cannot
        /// reuse the aim that just worked.
        ///
        /// The trophy is a child of the steps container, never of a step, so
        /// this is one animation inside one parent — and the cup stays on the
        /// podium's anchor, which is the anchor the balls are simulated on.
        /// The move doubles as the return from the celebratory swell.
        private func relocateCup() {
            guard !isTornDown, let trophy = trophyEntity else {
                isCupMoving = false
                return
            }

            // A ball lying in the cup would be left hanging in the air when the
            // cup slides out from under it. It has already been paid, so it
            // leaves with the cup.
            clearBallsInsideCup()

            currentStep = PodiumBuilder.nextStep(after: currentStep)
            let destination = trophyRestTransform
            _ = trophy.move(
                to: destination,
                relativeTo: trophy.parent,
                duration: Self.cupMoveDuration,
                timingFunction: .easeInOut
            )

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.cupMoveDuration * 1_000_000_000) + 30_000_000)
                guard let self, !self.isTornDown else { return }
                // Land exactly on the target pose rather than wherever the
                // animation stopped, so the next swell has a clean rest state.
                self.trophyEntity?.transform = self.trophyRestTransform
                self.isCupMoving = false
            }
        }

        /// The trophy's pose when nothing is animating: upright, unscaled, on
        /// whichever step the cup currently belongs to.
        private var trophyRestTransform: Transform {
            Transform(
                scale: .one,
                rotation: simd_quatf(angle: 0, axis: [0, 1, 0]),
                translation: currentStep.trophyPosition
            )
        }

        private func clearBallsInsideCup() {
            guard cupEntity != nil else { return }
            var survivors: [LiveBall] = []
            for ball in balls {
                guard let placement = cupPlacement(of: ball.entity),
                      toss.isInsideCup(placement, ballRadius: toss.tuning.ballRadius)
                else {
                    survivors.append(ball)
                    continue
                }
                ball.entity.removeFromParent()
                toss.retire(ball.id)
            }
            balls = survivors
        }

        /// A short swell of the trophy, used as the light cue for the +1 tier.
        /// Skipped while a make is being celebrated — that animation owns the
        /// trophy.
        private func pulse(scale: Float, rise: TimeInterval, fall: TimeInterval) {
            guard !isCupMoving, let trophy = trophyEntity else { return }
            let rest = trophyRestTransform
            var swollen = rest
            swollen.scale = rest.scale * scale
            _ = trophy.move(to: swollen, relativeTo: trophy.parent, duration: rise, timingFunction: .easeOut)

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(rise * 1_000_000_000) + 10_000_000)
                guard let self, !self.isTornDown, !self.isCupMoving,
                      let trophy = self.trophyEntity
                else { return }
                _ = trophy.move(
                    to: self.trophyRestTransform,
                    relativeTo: trophy.parent,
                    duration: fall,
                    timingFunction: .easeInOut
                )
            }
        }

        // MARK: - Culling (FR-006, SC-006)

        /// One frame of the game: the round clock, then the balls.
        private func step(deltaTime: TimeInterval) {
            guard !isTornDown else { return }
            model.tick(deltaTime)
            stepBalls(deltaTime: deltaTime)
        }

        /// Runs once per rendered frame: ages every live ball, tracks how long
        /// it has been still, and removes it once `TossController` says it is
        /// litter — at rest, off the table, or simply too old. This is what
        /// keeps a minute of spam-flicking bounded (SC-006).
        ///
        /// The one exception is a ball balanced on the cup's rim: culling it
        /// there is what Gate 3 row 3.2 saw as balls "disappearing", so instead
        /// it gets shoved (``nudgeOffRim(_:)``) and given its time back, up to
        /// `Tuning.maximumRimNudges` times, until it visibly drops in or out.
        private func stepBalls(deltaTime: TimeInterval) {
            guard !balls.isEmpty, let anchor = podiumAnchor else { return }

            var survivors: [LiveBall] = []
            survivors.reserveCapacity(balls.count)
            // Collected rather than credited on the spot: a make relocates the
            // cup, which culls balls, and that must not happen underneath this
            // loop's own rebuild of `balls`.
            var landed: [TossController.BallID] = []

            for var ball in balls {
                ball.age += deltaTime
                let speed = simd_length(ball.entity.physicsMotion?.linearVelocity ?? .zero)
                ball.restingFor = toss.restingDuration(
                    previous: ball.restingFor,
                    speed: speed,
                    delta: deltaTime
                )
                let height = ball.entity.position(relativeTo: anchor).y
                let placement = cupPlacement(of: ball.entity)

                // FR-005 / SC-002: the make is a geometric fact that has to
                // hold for `insideDwell` seconds, not a sensor contact. A ball
                // punched through the wall or skimming past crosses the
                // interior in a frame or two and never gets there.
                let inside = !isCupMoving && placement.map {
                    toss.isInsideCup($0, ballRadius: toss.tuning.ballRadius)
                } ?? false
                ball.insideFor = toss.containedDuration(
                    previous: ball.insideFor,
                    isInside: inside,
                    delta: deltaTime
                )
                if toss.hasSettledInside(containedFor: ball.insideFor), !toss.hasMade(ball.id) {
                    landed.append(ball.id)
                }

                let reason = toss.cullReason(
                    age: ball.age,
                    restingFor: ball.restingFor,
                    heightAboveAnchor: height
                )

                guard let reason else {
                    survivors.append(ball)
                    continue
                }

                if reason != .outOfBounds,
                   toss.mayNudgeOffRim(nudgesSoFar: ball.rimNudges),
                   let placement,
                   toss.isPerchedOnRim(
                       placement,
                       ballRadius: toss.tuning.ballRadius,
                       cupOuterRadius: PodiumBuilder.Metrics.cupRimOuterRadius
                   ) {
                    nudgeOffRim(ball.entity)
                    ball.rimNudges += 1
                    ball.restingFor = 0
                    ball.age = max(0, ball.age - toss.tuning.rimNudgeGrace)
                    survivors.append(ball)
                    continue
                }

                ball.entity.removeFromParent()
                toss.retire(ball.id)
            }

            balls = survivors
            for ball in landed {
                creditMake(ball)
            }
        }

        // MARK: - Where a ball is relative to the cup

        /// The ball's position in the cup's own frame, in the shape both cup
        /// rules — inside (FR-005) and perched on the rim (Gate 3 row 3.2) —
        /// are written against. `nil` before the podium is placed.
        private func cupPlacement(of ball: ModelEntity) -> TossController.CupPlacement? {
            guard let cup = cupEntity else { return nil }
            return PodiumBuilder.cupPlacement(ofBallAt: ball.position(relativeTo: cup))
        }

        /// Tips a perched ball off the rim in a random direction, so it falls
        /// in or out instead of sitting there until the culler deletes it.
        ///
        /// The velocity is written straight into `PhysicsMotionComponent`
        /// rather than applied as an impulse: a ball that has been still for a
        /// second may have been put to sleep by the solver, and setting the
        /// motion component is the reliable way to get it moving again.
        private func nudgeOffRim(_ ball: ModelEntity) {
            let azimuth = Float.random(in: 0..<(2 * .pi))
            var motion = ball.components[PhysicsMotionComponent.self] ?? PhysicsMotionComponent()
            motion.linearVelocity += toss.rimNudgeVelocity(azimuth: azimuth)
            ball.components.set(motion)
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
            Task { @MainActor in self.applyTrackingIssue(issue) }
        }

        nonisolated func sessionWasInterrupted(_ session: ARSession) {
            Task { @MainActor in
                self.applyTrackingIssue("Sesión en pausa. Vuelve a apuntar a la superficie.")
            }
        }

        nonisolated func sessionInterruptionEnded(_ session: ARSession) {
            // Deliberately no `run(_:options:)` here: ARKit resumes on its own
            // and relocalises to the existing anchor. Resetting would move the
            // podium, which the spec forbids.
            Task { @MainActor in self.applyTrackingIssue(nil) }
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
            contactSubscription = nil
            cupContactIDs = []

            balls.removeAll()
            toss.retireAll()
            trophyEntity = nil
            cupEntity = nil
            isCupMoving = false
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
