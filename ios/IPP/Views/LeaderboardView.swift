import SwiftUI

struct LeaderboardView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: SessionService
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [LeaderboardEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showingGame = false

    /// The AR mini-game only runs where ARKit world tracking does — elsewhere
    /// (Simulator, unsupported hardware) the entry point stays disabled with an
    /// explanation (FR-001). Reading this never touches the camera.
    private var gameAvailable: Bool { ARSupport.isWorldTrackingSupported }

    var body: some View {
        NavigationStack {
            List {
                if let username = session.username {
                    Section {
                        heroCard(username: username)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                } else if session.isViewer {
                    Section("Mi cuenta") {
                        Text("Visitante - sin atribución en el ranking.")
                            .font(.callout)
                            .foregroundStyle(Color.ippBody)
                    }
                }

                Section {
                    gameRow
                } footer: {
                    Text(gameAvailable
                         ? "Mini-juego de realidad aumentada. Es solo por diversión: no cambia tus puntos."
                         : ARSupport.unsupportedMessage)
                }

                Section {
                    if loading {
                        HStack { ProgressView(); Text("Cargando…") }
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                    } else if entries.isEmpty {
                        Text("Sin datos todavía.").foregroundStyle(Color.ippMuted)
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                            LeaderboardRow(
                                rank: idx + 1,
                                entry: entry,
                                isMe: entry.doctor == session.username
                            )
                        }
                    }
                } header: {
                    Text("Tabla del equipo")
                } footer: {
                    Text("Puntos: +1000 por ficha · +20 por campo · +10 por búsqueda.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.ippScreen)
            .navigationTitle("Ranking de puntos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Listo") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await load() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await load() }
            .fullScreenCover(isPresented: $showingGame) {
                TrophyTossView()
            }
        }
    }

    private var gameRow: some View {
        Button {
            showingGame = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(gameAvailable ? Color.ippGoldSoft : Color(.tertiarySystemFill))
                        .frame(width: 36, height: 36)
                    Image(systemName: "trophy.fill")
                        .font(.title3)
                        .foregroundStyle(gameAvailable ? Color.ippGold : Color.ippMuted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jugar")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(gameAvailable ? Color.ippInk : Color.ippMuted)
                    Text("Tiro al Trofeo · encesta en el podio")
                        .font(.caption)
                        .foregroundStyle(Color.ippMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ippFaint)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!gameAvailable)
        .opacity(gameAvailable ? 1 : 0.55)
    }

    private func heroCard(username: String) -> some View {
        let mine = entries.first { $0.doctor == username }
        let rank = entries.firstIndex { $0.doctor == username }.map { $0 + 1 }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Tus puntos")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text((mine?.points ?? 0).formatted())
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if let rank {
                    Text("· #\(rank) de \(entries.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            if let addr = session.walletAddress {
                Text(CardanoWallet.shortAddress(addr))
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(LinearGradient.ippBrand)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func load() async {
        loading = true
        error = nil
        do {
            entries = try await env.fetchLeaderboard()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private struct LeaderboardRow: View {
    let rank: Int
    let entry: LeaderboardEntry
    let isMe: Bool

    private var medalColor: Color? {
        switch rank {
        case 1: return Color(red: 0.95, green: 0.78, blue: 0.18)
        case 2: return Color(red: 0.75, green: 0.78, blue: 0.82)
        case 3: return Color(red: 0.80, green: 0.50, blue: 0.20)
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isMe ? Color.ippTint : Color(.tertiarySystemFill))
                    .frame(width: 36, height: 36)
                if let medalColor {
                    Image(systemName: "trophy.fill")
                        .foregroundStyle(medalColor)
                        .font(.title3)
                } else {
                    Text("\(rank)").font(.callout.bold()).foregroundStyle(Color.ippMuted)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.doctor)
                    .font(.callout.weight(isMe ? .semibold : .regular))
                    .foregroundStyle(Color.ippInk)
                Text("\(entry.total) fichas · \(entry.fields) campos · \(entry.searches) búsq.")
                    .font(.caption)
                    .foregroundStyle(Color.ippMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.points.formatted())
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(Color.ippTeal)
                Text("puntos").font(.caption2).foregroundStyle(Color.ippMuted)
            }
        }
        .padding(.vertical, 2)
    }
}
