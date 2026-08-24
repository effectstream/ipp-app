import SwiftUI
import UIKit

/// Entry screen of the "Tiro al Trofeo" AR mini-game, launched from the
/// leaderboard.
///
/// This screen owns the camera-permission story: it asks for the camera when it
/// appears — the only moment the app ever asks (FR-010) — and renders a Spanish
/// explanation with a shortcut to Ajustes when the answer is no. The AR scene
/// itself arrives in a later phase; for now `readyState` is its placeholder.
///
/// The game is fully offline: this file makes no network request and never
/// touches `AppEnvironment` or the leaderboard data (FR-008).
struct TrophyTossView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var permission: ARSupport.CameraPermission = .notDetermined
    @State private var isAsking = false
    /// Guards against asking twice if the view's task runs again.
    @State private var didAsk = false

    var body: some View {
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
        .task { await askForCameraIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            // Returning from Ajustes: the player may have changed the answer.
            if phase == .active { permission = ARSupport.cameraPermission }
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
            case .granted: readyState
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

    /// Placeholder for the AR content that a later phase installs here.
    private var readyState: some View {
        card(icon: "checkmark.circle.fill", tint: .ippTeal, title: "Cámara lista") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ya podemos usar la cámara. La vista de realidad aumentada con el podio se añade en la siguiente entrega.")
                    .font(.callout)
                    .foregroundStyle(Color.ippBody)
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        Color.ippFaint,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
                    .frame(height: 180)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "arkit")
                                .font(.largeTitle)
                                .foregroundStyle(Color.ippFaint)
                            Text("Vista AR · próximamente")
                                .font(.caption)
                                .foregroundStyle(Color.ippMuted)
                        }
                    )
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
