import BlackHoleCore
import AppKit
import SwiftUI

/// Every tunable, one slider each. Behind a menu item on purpose — Size and
/// Style are meant to be enough.
struct AdvancedPanel: View {
    @ObservedObject var params: Params
    @ObservedObject var model: AppModel
    @ObservedObject var cycler: StyleCycler

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
                // Always shown, not only when the capture is complaining: this
                // is the one place the lens can be turned back *off*. The menu
                // bar only ever offers to turn it on, so that a widget doing its
                // job stays a two-item menu.
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: Binding(get: { model.lens },
                                                      set: { model.lens = $0 })) {
                            ForEach(LensSource.allCases) { source in
                                Text(source.label).tag(source)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .help("Live screen records the screen behind the widget so that it can bend it. Without it the widget draws the hole and the disk over nothing, and macOS is never asked for Screen Recording.")
                        if let status = model.captureStatus {
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
                    }
                    .padding(6)
                } label: {
                    Text("Lens").font(.headline)
                        .foregroundStyle(model.captureStatus == nil ? Color.primary : Color.orange)
                }

                ForEach(Specs.grouped(), id: \.0) { group, members in
                    GroupBox {
                        VStack(spacing: 6) {
                            ForEach(members, id: \.self) { name in
                                ParamRow(params: params, cycler: cycler, name: name)
                            }
                        }
                        .padding(6)
                    } label: {
                        Text(group).font(.headline)
                    }
                }

                Button("Reset everything") {
                    cycler.stop()
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
    @ObservedObject var cycler: StyleCycler
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
                        cycler.stop()
                        params[name] = spec.def
                        params.save()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to \(format(spec.def))")
                }
            }
            // Tuning by hand stops the style rotation, on the grab rather than
            // on the release: a slider you are still holding when the hour turns
            // would otherwise be dragged out from under you.
            Slider(
                value: Binding(get: { params[name] }, set: { params[name] = $0 }),
                in: spec.range,
                onEditingChanged: { editing in
                    if editing { cycler.stop() } else { params.save() }
                }
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
