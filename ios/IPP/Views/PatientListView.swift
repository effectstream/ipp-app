import SwiftUI

// Sheet presented from HomeView for "Buscar Paciente". The patient list with
// search, plus push-navigation into individual records.
struct PatientListView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var patients: [Patient] = []
    @State private var searchText: String = ""

    private var filtered: [Patient] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return patients }
        return patients.filter {
            $0.nombre.lowercased().contains(q)
                || $0.rut.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if patients.isEmpty {
                    EmptyState()
                } else {
                    List {
                        ForEach(filtered) { patient in
                            NavigationLink(value: patient) {
                                PatientRow(patient: patient)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Buscar Paciente")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Buscar por nombre o RUT")
            .onSubmit(of: .search) {
                Task { await env.recordSearch() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }
                }
            }
            .navigationDestination(for: Patient.self) { patient in
                PatientFormView(patient: patient)
            }
            .task { await refresh() }
            .refreshable { await refresh() }
        }
    }

    private func refresh() async {
        // Straight to the store, so the wait for the launch probe has to be
        // explicit here (question Q8).
        await env.backendReady()
        if let list = try? await env.store.list() {
            patients = list
        }
    }
}

private struct PatientRow: View {
    let patient: Patient

    private var initials: String {
        let s = patient.nombre.split(separator: " ").prefix(2)
            .compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.ippTint).frame(width: 38, height: 38)
                Text(initials).font(.caption.weight(.bold)).foregroundStyle(Color.ippTeal)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(patient.nombre.isEmpty ? "Sin nombre" : patient.nombre)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.ippInk)
                HStack(spacing: 6) {
                    if !patient.rut.isEmpty {
                        Text(patient.rut).font(.caption.monospaced()).foregroundStyle(Color.ippMuted)
                    }
                    if let edad = patient.edad {
                        Text("· \(edad) años").font(.caption).foregroundStyle(Color.ippMuted)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Sin pacientes registrados")
                .font(.headline)
            Text("Vuelve y elige “Nuevo Ingreso” para registrar al primer paciente.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
