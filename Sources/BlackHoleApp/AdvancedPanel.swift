import BlackHoleCore
import AppKit
import SwiftUI

/// Every tunable, one slider each. Behind a menu item on purpose — Size and
/// Style are meant to be enough.
struct AdvancedPanel: View {
    @ObservedObject var params: Params
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let error = model.rendererError {
                    GroupBox {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .textSelection(.enabled)
                            .padding(6)
                    } label: {
                        Text("Renderer failed").font(.headline).foregroundStyle(.red)
                    }
                }
                if let status = model.captureStatus {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(status).font(.caption).fixedSize(horizontal: false, vertical: true)
                            if model.captureDenied {
                                HStack(spacing: 8) {
                                    Button("Ask again") { ScreenCapture.shared.resetPermissionAndRetry() }
                                        .help("Clears this app's Screen Recording decision so macOS prompts again")
                                    Button("Open Settings") {
                                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(6)
                    } label: {
                        Text("Lens").font(.headline).foregroundStyle(.orange)
                    }
                }

                ForEach(Specs.grouped(), id: \.0) { group, members in
                    GroupBox {
                        VStack(spacing: 6) {
                            ForEach(members, id: \.self) { name in
                                ParamRow(params: params, name: name)
                            }
                        }
                        .padding(6)
                    } label: {
                        Text(group).font(.headline)
                    }
                }

                Button("Reset everything") {
                    params.resetAll()
                }
                .padding(.top, 4)
            }
            .padding(12)
        }
        .frame(minWidth: 340)
    }
}

private struct ParamRow: View {
    @ObservedObject var params: Params
    let name: String

    private var spec: ParamSpec { Specs.spec(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.caption.monospaced())
                Spacer()
                Text(format(params[name]))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if abs(params[name] - spec.def) > 1e-9 {
                    Button {
                        params[name] = spec.def
                        params.save()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to \(format(spec.def))")
                }
            }
            Slider(
                value: Binding(get: { params[name] }, set: { params[name] = $0 }),
                in: spec.range,
                onEditingChanged: { editing in if !editing { params.save() } }
            )
        }
        .help(spec.help)
    }

    private func format(_ v: Double) -> String {
        let span = spec.range.upperBound - spec.range.lowerBound
        if span >= 500 { return String(format: "%.0f", v) }
        if span >= 5 { return String(format: "%.2f", v) }
        return String(format: "%.4f", v)
    }
}
