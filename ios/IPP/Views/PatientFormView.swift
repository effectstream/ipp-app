import SwiftUI

struct PatientFormView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var schemaService: SchemaService
    @EnvironmentObject private var session: SessionService
    @Environment(\.dismiss) private var dismiss
    @State var patient: Patient
    var isNew: Bool = false

    @State private var saving = false
    @State private var saved = false
    @State private var savedMessage: String = ""
    @State private var saveError: String?
    @State private var copiedHint: Bool = false
    @State private var showDiscardConfirm = false
    @State private var originalSnapshot: Patient?

    @State private var verifying = false
    @State private var verifyResult: VerifyResult?
    @State private var verifyError: String?

    @State private var fieldStats: FieldStatsBundle?

    private var schema: FormSchema { schemaService.schema }
    private var isViewer: Bool { session.isViewer }

    private var sortedTabs: [FormTab] {
        schema.tabs.sorted { $0.order < $1.order }
    }

    // Re-fetch field-stats whenever the patient's coordinates change (e.g. the
    // doctor picks an address), so "local" compares against the right area.
    private var coordsKey: String {
        "\(patient.latitude ?? 0)|\(patient.longitude ?? 0)"
    }

    // "Dirty" if the current patient differs from the snapshot we took when
    // the view first appeared. Viewers can't save so we never treat their
    // changes as dirty.
    private var hasUnsavedChanges: Bool {
        guard !isViewer, let original = originalSnapshot else { return false }
        return original != patient
    }

    var body: some View {
        TabView {
            ForEach(sortedTabs, id: \.id) { tab in
                tabContent(tab)
                    .tabItem {
                        Label(
                            tab.label,
                            systemImage: tab.icon ?? "doc.text"
                        )
                    }
            }
        }
        .navigationTitle(patient.nombre.isEmpty ? "Nuevo paciente" : patient.nombre)
        .navigationBarTitleDisplayMode(.inline)
        // Block the swipe-down dismiss while there are unsaved edits - the
        // user must hit Cancelar (or Guardar) so they see the discard
        // confirmation. iOS Mail's compose sheet does the same thing.
        .interactiveDismissDisabled(hasUnsavedChanges)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isViewer {
                    Text("Visitante")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                } else {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("Guardar") }
                    }
                    .disabled(saving)
                }
            }
            if isNew {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { attemptCancel() }
                }
            }
        }
        .onAppear {
            if originalSnapshot == nil { originalSnapshot = patient }
        }
        .task(id: coordsKey) {
            fieldStats = await env.fetchFieldStats(lat: patient.latitude, lng: patient.longitude)
        }
        .confirmationDialog(
            "¿Descartar cambios?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Descartar", role: .destructive) { dismiss() }
            Button("Continuar editando", role: .cancel) {}
        } message: {
            Text("Los datos ingresados se perderán.")
        }
        .alert("Paciente guardado", isPresented: $saved) {
            Button("OK") {
                if isNew { dismiss() }
            }
        } message: {
            Text(savedMessage)
        }
        .alert("Error", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: FormTab) -> some View {
        if tab.id == sortedTabs.first?.id, let code = patient.passcode, !code.isEmpty {
            VStack(spacing: 0) {
                passcodeBanner(code: code)
                verifyBanner()
                DynamicFormView(tabId: tab.id, responses: $patient.responses, stats: fieldStats)
            }
        } else {
            DynamicFormView(tabId: tab.id, responses: $patient.responses, stats: fieldStats)
        }
    }

    private func passcodeBanner(code: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Código de acceso del paciente")
                    .font(.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    withAnimation { copiedHint = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { copiedHint = false }
                    }
                } label: {
                    Label(copiedHint ? "Copiado" : "Copiar", systemImage: copiedHint ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text(code)
                .font(.title2.monospaced())
                .kerning(4)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
    }

    // -- On-chain verification ---------------------------------------------

    @ViewBuilder
    private func verifyBanner() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Verificación en cadena")
                    .font(.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await verify() }
                } label: {
                    if verifying {
                        ProgressView()
                    } else {
                        Label("Verificar", systemImage: "checkmark.shield").font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(verifying || patient.rut.isEmpty)
            }

            if let v = verifyResult {
                let verdict = verifyVerdict(v)
                Label(verdict.title, systemImage: verdict.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(verdict.color)
                Text(verdict.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let tx = v.chainTxId, !tx.isEmpty {
                    Text("Tx: \(tx.prefix(16))…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if let e = verifyError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
    }

    // Verdict uses the device-recomputed hash (PatientHasher) as the
    // authoritative "does this record match the chain" signal - the iOS
    // encoder is the one that produced the anchor in the first place.
    private func verifyVerdict(
        _ v: VerifyResult
    ) -> (title: String, detail: String, icon: String, color: Color) {
        if let err = v.readError, !err.isEmpty {
            return ("No se pudo leer la cadena", err, "exclamationmark.triangle", .secondary)
        }
        if v.chain == "local" && !v.found {
            return ("Cadena local",
                    "El backend no está conectado a Cardano; no hay anclaje real que verificar.",
                    "info.circle", .secondary)
        }
        let localHash = try? PatientHasher.sha256Hex(patient)
        if v.found, let oc = v.onChainHash, let lh = localHash, oc == lh {
            return ("Verificado en Cardano",
                    "El hash del registro actual coincide con el valor anclado en la cadena.",
                    "checkmark.seal.fill", .green)
        }
        if v.found, v.chainMatch {
            return ("El registro cambió desde el anclaje",
                    "La cadena conserva el hash original; el registro actual difiere.",
                    "exclamationmark.triangle.fill", .orange)
        }
        if v.found {
            return ("No coincide con la cadena",
                    "El valor en la cadena no coincide con este registro.",
                    "xmark.seal.fill", .red)
        }
        if v.anchoredHash != nil {
            return ("Anclado, no encontrado en la cadena",
                    "Se registró un anclaje pero la cadena no devuelve un valor (¿indexador sin sincronizar?).",
                    "exclamationmark.triangle", .orange)
        }
        return ("Sin anclaje en la cadena",
                "Este registro aún no ha sido anclado en Cardano.",
                "circle.dashed", .secondary)
    }

    private func verify() async {
        verifying = true
        verifyError = nil
        verifyResult = nil
        defer { verifying = false }
        do {
            // Straight to the client, so the wait for the launch probe has to
            // be explicit here (question Q8).
            await env.backendReady()
            verifyResult = try await env.effectStream.verify(rut: patient.rut)
        } catch {
            verifyError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func attemptCancel() {
        if hasUnsavedChanges {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    private func save() async {
        // The backend requires a valid RUT (the patient's identity + lookup
        // key). Validate locally so the doctor gets a clear, immediate message
        // naming the problem instead of a round-trip 400.
        if let problem = validationProblem() {
            saveError = problem
            return
        }
        saving = true
        defer { saving = false }
        if let updated = await env.saveAndAnchor(patient) {
            patient = updated
            originalSnapshot = updated  // saved → no longer dirty
            let code = updated.passcode ?? "-"
            let tx = env.lastAnchor?.txId ?? "-"
            let chain = env.lastAnchor?.chain ?? "-"
            savedMessage = "Código de acceso: \(code)\nHash anclado en \(chain).\nTx: \(tx)"
            saved = true
        } else if let err = env.lastError {
            saveError = err
        }
    }

    // Mirrors the backend RUT rule (RUT_PATTERN: 5-15 chars of digits, K, dots
    // and hyphen). Returns a user-facing message naming the problem, or nil
    // when the record is OK to submit.
    private func validationProblem() -> String? {
        let rut = patient.rut.trimmingCharacters(in: .whitespacesAndNewlines)
        if rut.isEmpty {
            return "Ingresa el RUT del paciente para guardar."
        }
        let allowed = CharacterSet(charactersIn: "0123456789kK.-")
        guard (5...15).contains(rut.count),
              rut.unicodeScalars.allSatisfy(allowed.contains) else {
            return "El RUT no es válido. Usa números, puntos, guion y dígito verificador (ej: 12.345.678-9)."
        }
        return nil
    }
}
