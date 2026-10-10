import SwiftUI
import TxCore

struct DictationSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var settings: DictationSettings = DictationSettings.load()
    @State private var inputMonitoring: DictationPermission = .notDetermined
    @State private var accessibility: DictationPermission = .notDetermined
    @State private var microphone: DictationPermission = .notDetermined

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                permissionsSection
                hotkeySection
                pasteSection
                historySection
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear { refreshPermissions() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ditado por voz")
                .font(.title2.bold())
            Text("Configure atalhos, permissões e comportamento do ditado global.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        GroupBox("Permissões") {
            VStack(alignment: .leading, spacing: 10) {
                permRow("Microphone", status: microphone) {
                    openSystemSettings("Privacy_Microphone")
                }
                permRow("Input Monitoring", status: inputMonitoring) {
                    _ = GlobalHotkeyManager.requestInputMonitoringPermission()
                    openSystemSettings("Privacy_ListenEvent")
                }
                permRow("Accessibility", status: accessibility) {
                    _ = PasteSimulator.requestAccessibilityPermission()
                    openSystemSettings("Privacy_Accessibility")
                }
                Button("Revalidar permissões") { refreshPermissions() }
                    .controlSize(.small)
            }
            .padding(8)
        }
    }

    private func permRow(_ title: String, status: DictationPermission, open: @escaping () -> Void) -> some View {
        HStack {
            Text(InterfaceStrings.text(title)).frame(width: 160, alignment: .leading)
            statusIndicator(for: status)
            Spacer()
            Button("Abrir ajustes", action: open)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func statusIndicator(for status: DictationPermission) -> some View {
        switch status {
        case .granted:
            Label("Concedida", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Label("Negada", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .notDetermined:
            Label("Não verificada", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private var hotkeySection: some View {
        GroupBox("Atalho Fn") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Segure Fn para ditar. Aperte Fn duas vezes para travar a gravação. ESC cancela.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                stepper("Hold mínimo (ms)", value: $settings.holdThresholdMs, range: 100...500, step: 25)
                stepper("Janela double-tap (ms)", value: $settings.doubleTapWindowMs, range: 150...600, step: 25)
                stepper("Descarte se < (ms)", value: $settings.minDurationMs, range: 0...2000, step: 50)

                Button("Aplicar") { applySettings() }
                    .controlSize(.small)
            }
            .padding(8)
        }
    }

    private var pasteSection: some View {
        GroupBox("Paste") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Preservar clipboard atual durante o paste", isOn: $settings.preserveClipboard)
                    .onChange(of: settings.preserveClipboard) { _, _ in applySettings() }
                Toggle("Salvar arquivo de áudio de cada ditado", isOn: $settings.saveAudio)
                    .onChange(of: settings.saveAudio) { _, _ in applySettings() }

                stepper("Espera após setString (ms)", value: $settings.pasteWaitAfterSetMs, range: 0...200, step: 10)
                stepper("Espera antes de restaurar (ms)", value: $settings.pasteWaitBeforeRestoreMs, range: 50...1000, step: 50)

                Button("Aplicar") { applySettings() }
                    .controlSize(.small)
            }
            .padding(8)
        }
    }

    private var historySection: some View {
        GroupBox("Histórico") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Os ditados ficam salvos localmente em SQLite.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    try? appState.dictationStore.deleteAll()
                } label: {
                    Label("Apagar todos os ditados", systemImage: "trash")
                }
                .controlSize(.small)
            }
            .padding(8)
        }
    }

    private func stepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        HStack {
            Text(InterfaceStrings.text(label)).frame(width: 220, alignment: .leading)
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)").monospacedDigit()
            }
        }
    }

    private func applySettings() {
        settings.save()
        appState.applyDictationSettings(settings)
    }

    private func refreshPermissions() {
        inputMonitoring = GlobalHotkeyManager.hasInputMonitoringPermission() ? .granted : .denied
        accessibility = PasteSimulator.hasAccessibilityPermission() ? .granted : .denied
        microphone = .notDetermined // TCC não expõe leitura direta; trataremos via tentativa
    }

    private func openSystemSettings(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        if let url { NSWorkspace.shared.open(url) }
    }
}
