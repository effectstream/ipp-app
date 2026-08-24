import SwiftUI
import UIKit

/// Entry screen of the "Tiro al Trofeo" AR mini-game, launched from the
/// leaderboard.
///
/// Two faces, chosen by whether the game can actually run:
/// - the **AR screen** (`gameScreen`) — a full-bleed `PodiumARViewContainer`
///   with a thin Spanish overlay: hint, Reubicar, close, the round HUD
///   (countdown + score) and the end-of-round summary
///   (FR-002, FR-005, FR-007, FR-009);
/// - the **explainer screen** (`infoScreen`) — the camera-permission story.
///   It asks for the camera when this view appears, the only moment the app
///   ever asks (FR-010), and offers a shortcut to Ajustes when the answer is no.
///
/// Closing the screen removes the AR container, which tears the session down
/// (FR-011). The game is fully offline: this file makes no network request and
/// never touches `AppEnvironment` or the leaderboard data (FR-008).
struct TrophyTossView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var permission: ARSupport.CameraPermission = .notDetermined
    @State private var isAsking = false
    /// Guards against asking twice if the view's task runs again.
    @State private var didAsk = false

    /// State shared with the `ARView`. Lives here so it survives the AR view's
    /// own updates, and dies with this screen.
    @StateObject private var arModel = PodiumARModel()

    private var canPlay: Bool {
        ARSupport.isWorldTrackingSupported && permission == .granted
    }

    var body: some View {
        Group {
            if canPlay {
                gameScreen
            } else {
                infoScreen
            }
        }
        .task { await askForCameraIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            // Returning from Ajustes: the player may have changed the answer.
            if phase == .active { permission = ARSupport.cameraPermission }
            // A round must not burn its clock while the app is away (FR-007,
            // edge case "backgrounding mid-round").
            arModel.setPaused(phase != .active, reason: .backgrounded)
        }
    }

    // MARK: - AR screen

    private var gameScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PodiumARViewContainer(model: arModel)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                if arModel.isPlaced {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        relocateButton
                    }
                }
                Spacer(minLength: 0)
                // Both are hidden behind the summary card rather than dimmed
                // under it — the overlay owns the screen while it is up.
                if !arModel.round.hasEnded {
                    if arModel.isPlaced && arModel.round.isIdle {
                        startButton
                    }
                    hintBar
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)

            if arModel.round.hasEnded {
                summaryOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.snappy(duration: 0.28), value: arModel.round.hasEnded)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Label("Cerrar", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.ippInk.opacity(0.55), in: Circle())
            .accessibilityLabel("Cerrar el juego")

            Spacer(minLength: 0)

            if arModel.round.isRunning {
                countdownPill
            }

            if arModel.isPlaced {
                scorePill
            }
        }
    }

    /// Time left in the round (FR-007). Turns gold under ten seconds and says
    /// so out loud when the clock is stopped for tracking or backgrounding.
    private var countdownPill: some View {
        HStack(spacing: 7) {
            Image(systemName: arModel.round.isPaused ? "pause.fill" : "timer")
                .font(.subheadline.weight(.semibold))
            Text(arModel.round.countdownText)
                .font(.title3.weight(.bold))
                .monospacedDigit()
        }
        .foregroundStyle(countdownTint)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Color.ippInk.opacity(0.65), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(arModel.round.isPaused ? "Ronda en pausa" : "Tiempo restante")
        .accessibilityValue(arModel.round.countdownText)
    }

    private var countdownTint: Color {
        if arModel.round.isPaused { return .ippGold }
        return arModel.round.remaining <= 10 ? .ippGold : .white
    }

    /// Points: the round's while one is on, the free-practice tally before that.
    private var scorePill: some View {
        HStack(spacing: 7) {
            Image(systemName: "trophy.fill")
                .font(.subheadline.weight(.semibold))
            Text("\(arModel.displayedScore)")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(arModel.displayedScore)))
        }
        .foregroundStyle(Color.ippGold)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Color.ippInk.opacity(0.65), in: Capsule())
        .animation(.snappy(duration: 0.25), value: arModel.displayedScore)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(arModel.round.isIdle ? "Puntos de práctica" : "Puntos de la ronda")
        .accessibilityValue("\(arModel.displayedScore)")
    }

    /// Moving the podium mid-round would pull the target out from under a
    /// running clock, so the button is disabled rather than hidden — the player
    /// can see it will come back.
    private var relocateButton: some View {
        Button {
            arModel.relocate()
        } label: {
            Label("Reubicar", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(Color.ippTeal.opacity(arModel.canRelocate ? 0.92 : 0.35), in: Capsule())
        .opacity(arModel.canRelocate ? 1 : 0.55)
        .disabled(!arModel.canRelocate)
    }

    /// Starts a timed round (FR-007). Only appears once the podium is down —
    /// before that there is nothing to aim at.
    private var startButton: some View {
        Button {
            arModel.startRound()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Comenzar")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(LinearGradient.ippBrand, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Comenzar una ronda de \(Int(arModel.round.rules.duration)) segundos")
    }

    // MARK: - End-of-round summary (FR-007, FR-008)

    private var summaryOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                summaryCard
                summaryActions
            }
            .padding(.horizontal, 24)
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 10) {
            Text("Ronda terminada")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))

            Text("\(arModel.round.finalScore ?? 0)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            Text(scoreWord(arModel.round.finalScore ?? 0))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))

            if arModel.didSetRecord {
                Label("¡Nuevo récord!", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ippGold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.16), in: Capsule())
            } else {
                Text("Tu mejor marca: \(arModel.bestScore)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
        .background(LinearGradient.ippBrand)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var summaryActions: some View {
        VStack(spacing: 10) {
            Button {
                arModel.startRound()
            } label: {
                Text("Jugar de nuevo")
                    .font(.headline)
                    .foregroundStyle(Color.ippTealDeep)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                arModel.returnToPractice()
            } label: {
                Text("Seguir practicando")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)

            Button("Salir del juego") { dismiss() }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.top, 2)
        }
    }

    private func scoreWord(_ score: Int) -> String {
        score == 1 ? "punto" : "puntos"
    }

    private var hintBar: some View {
        HStack(spacing: 10) {
            Image(systemName: hintIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(hintTint)
            Text(arModel.hint)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.ippInk.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        .animation(.easeInOut(duration: 0.2), value: arModel.hint)
    }

    private var hintIcon: String {
        if arModel.failure != nil { return "exclamationmark.triangle.fill" }
        if arModel.trackingIssue != nil { return "viewfinder.trianglebadge.exclamationmark" }
        return arModel.isPlaced ? "trophy.fill" : "hand.tap.fill"
    }

    private var hintTint: Color {
        if arModel.failure != nil || arModel.trackingIssue != nil { return .ippGold }
        return .white.opacity(0.85)
    }

    // MARK: - Explainer screen

    private var infoScreen: some View {
        NavigationStack {
            ZStack {
                Color.ippScreen.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        heroCard
                        content
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                }
            }
            .navigationTitle("Tiro al Trofeo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "trophy.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                Text("Tiro al Trofeo")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
            }
            Text("Apunta a una mesa o al suelo, coloca el podio y encesta la pelota en la copa.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
            Text("Juego sin conexión · no cambia tus puntos del ranking.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(LinearGradient.ippBrand)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var content: some View {
        if !ARSupport.isWorldTrackingSupported {
            unsupportedState
        } else {
            switch permission {
            case .granted: openingState
            case .denied: deniedState
            case .restricted: restrictedState
            case .notDetermined: askingState
            }
        }
    }

    /// Reachable only if support disappears between the leaderboard check and
    /// this screen — the entry point is already gated on the same flag.
    private var unsupportedState: some View {
        card(icon: "iphone.slash", tint: .ippMuted, title: "No disponible aquí") {
            Text(ARSupport.unsupportedMessage)
                .font(.callout)
                .foregroundStyle(Color.ippBody)
        }
    }

    private var askingState: some View {
        card(icon: "camera.fill", tint: .ippTeal, title: "Permiso de cámara") {
            VStack(alignment: .leading, spacing: 12) {
                Text("El juego necesita la cámara para ver la superficie donde se apoya el podio. Las imágenes no se graban ni se envían.")
                    .font(.callout)
                    .foregroundStyle(Color.ippBody)
                if isAsking {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Esperando tu respuesta…")
                            .font(.caption)
                            .foregroundStyle(Color.ippMuted)
                    }
                } else {
                    Button("Permitir cámara") {
                        Task { await askForCamera() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.ippTeal)
                }
            }
        }
    }

    private var deniedState: some View {
        card(icon: "camera.badge.ellipsis", tint: .ippGold, title: "Sin acceso a la cámara") {
            VStack(alignment: .leading, spacing: 12) {
                Text("No podemos mostrar el podio sin la cámara. Puedes activarla en Ajustes › IPP › Cámara y volver a intentarlo.")
                    .font(.callout)
                    .foregroundStyle(Color.ippBody)
                Button("Abrir Ajustes") { openSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(.ippTeal)
            }
        }
    }

    private var restrictedState: some View {
        card(icon: "lock.fill", tint: .ippGold, title: "Cámara restringida") {
            VStack(alignment: .leading, spacing: 12) {
                Text("El acceso a la cámara está bloqueado en este dispositivo (control parental o perfil de gestión), así que el mini-juego no puede abrirse.")
                    .font(.callout)
                    .foregroundStyle(Color.ippBody)
                Button("Abrir Ajustes") { openSettings() }
                    .buttonStyle(.bordered)
                    .tint(.ippTeal)
            }
        }
    }

    /// Only ever on screen for the frame between the player granting the camera
    /// and `canPlay` swapping this whole screen for `gameScreen`.
    private var openingState: some View {
        card(icon: "camera.fill", tint: .ippTeal, title: "Abriendo la cámara") {
            HStack(spacing: 8) {
                ProgressView()
                Text("Preparando la vista de realidad aumentada…")
                    .font(.callout)
                    .foregroundStyle(Color.ippBody)
            }
        }
    }

    // MARK: - Building blocks

    private func card<Content: View>(
        icon: String,
        tint: Color,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(tint.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.ippInk)
                Spacer(minLength: 0)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.ippBorder, lineWidth: 1)
        )
    }

    // MARK: - Permission flow

    /// Runs when the game screen appears — this is the one place the app is
    /// allowed to raise the camera prompt (FR-010).
    private func askForCameraIfNeeded() async {
        permission = ARSupport.cameraPermission
        guard ARSupport.isWorldTrackingSupported,
              permission == .notDetermined,
              !didAsk
        else { return }
        await askForCamera()
    }

    private func askForCamera() async {
        guard !isAsking else { return }
        didAsk = true
        isAsking = true
        permission = await ARSupport.requestCameraAccess()
        isAsking = false
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
