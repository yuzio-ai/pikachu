import SwiftUI
import AgentRuntimeCore

struct ACPElicitationView: View {
    let request: RuntimeInteraction
    let elicitation: RuntimeElicitation
    let submitting: Bool
    let reply: (InteractionResponse) -> Void
    @Environment(\.openURL) private var openURL
    @State private var fields: [String: String] = [:]
    @State private var urlError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).pikachuFont(.title3, weight: .semibold)
            Text(request.message).textSelection(.enabled)
            switch elicitation {
            case .form(let definitions):
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(definitions) { field in
                            input(for: field)
                        }
                    }
                }
                .frame(maxHeight: 320)
            case .url(let url):
                Text(verbatim: url.absoluteString).textSelection(.enabled)
                if urlError {
                    Text("无法打开外部链接。").foregroundStyle(PikachuTheme.errorText)
                }
            }
            HStack {
                Button("取消") { reply(.cancelled) }
                    .keyboardShortcut(.cancelAction)
                Button("拒绝") { reply(.confirmed(false)) }
                Spacer()
                switch elicitation {
                case .form(let definitions):
                    Button("提交") {
                        if let response = formResponse(definitions) { reply(response) }
                    }
                    .disabled(formResponse(definitions) == nil)
                case .url(let url):
                    Button("打开浏览器") {
                        openURL(url) { accepted in
                            if accepted { reply(.confirmed(true)) }
                            else { urlError = true }
                        }
                    }
                }
            }
            .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
        }
        .disabled(submitting)
        .onAppear {
            if case .form(let definitions) = elicitation {
                fields = Dictionary(uniqueKeysWithValues: definitions.compactMap { field in
                    field.defaultValue.map { initial in
                        (field.id, field.kind == .boolean ? (initial == "1" ? "true" : "false") : initial)
                    }
                })
            }
        }
    }

    @ViewBuilder private func input(for field: RuntimeElicitationField) -> some View {
        let binding = Binding(get: { fields[field.id] ?? "" }, set: { fields[field.id] = $0 })
        if field.kind == .array {
            VStack(alignment: .leading, spacing: 4) {
                Text(field.title)
                ForEach(field.choices, id: \.self) { choice in
                    Toggle(choice, isOn: Binding(get: {
                        binding.wrappedValue.components(separatedBy: "\n").contains(choice)
                    }, set: { enabled in
                        var selected = Set(binding.wrappedValue.components(separatedBy: "\n"))
                        if enabled { selected.insert(choice) } else { selected.remove(choice) }
                        binding.wrappedValue = field.choices.filter { selected.contains($0) }.joined(separator: "\n")
                    }))
                }
            }
        } else if field.kind == .boolean || !field.choices.isEmpty {
            Picker(field.title, selection: binding) {
                Text("请选择").tag("")
                if field.kind == .boolean {
                    Text("是").tag("true")
                    Text("否").tag("false")
                } else {
                    ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                }
            }
        } else {
            TextField(field.title, text: binding)
        }
    }

    private func formResponse(_ definitions: [RuntimeElicitationField]) -> InteractionResponse? {
        var values: [String: Any] = [:]
        for field in definitions {
            guard let input = fields[field.id], !input.isEmpty else {
                if field.required { return nil }
                continue
            }
            switch field.kind {
            case .string: values[field.id] = input
            case .boolean: values[field.id] = input == "true"
            case .array: values[field.id] = input.components(separatedBy: "\n")
            case .integer:
                guard let number = Int(input) else { return nil }
                values[field.id] = number
            case .number:
                guard let number = Double(input), number.isFinite else { return nil }
                values[field.id] = number
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let encoded = String(data: data, encoding: .utf8) else { return nil }
        return .value(encoded)
    }
}
