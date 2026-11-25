import CoreFoundation
import Foundation
import AgentRuntimeCore
import ProcessSupervision

struct ACPElicitation {
    let display: RuntimeElicitation
    let externalID: String?
    let properties: [String: Record]

    init?(_ params: Record) {
        switch params["mode"] as? String {
        case "url":
            guard let rawID = params["elicitationId"] as? String, !rawID.isEmpty,
                  let address = params["url"] as? String,
                  let url = URL(string: address), url.scheme?.lowercased() == "https",
                  url.host != nil, url.user == nil, url.password == nil else { return nil }
            externalID = rawID
            display = .url(url)
            properties = [:]
        case "form":
            guard let schema = params["requestedSchema"] as? Record,
                  schema["type"] as? String == "object",
                  let fields = schema["properties"] as? [String: Record], fields.count <= 32 else { return nil }
            let required = Set(schema["required"] as? [String] ?? [])
            guard required.isSubset(of: Set(fields.keys)) else { return nil }
            var descriptions: [RuntimeElicitationField] = []
            for (id, property) in fields.sorted(by: { $0.key < $1.key }) {
                guard let rawKind = property["type"] as? String,
                      let kind = RuntimeElicitationField.Kind(rawValue: rawKind) else { return nil }
                let choices = Self.choices(kind == .array ? (property["items"] as? Record ?? [:]) : property)
                guard kind != .array || !choices.isEmpty else { return nil }
                let initial = property["default"]
                let defaultValue = (initial as? [String])?.joined(separator: "\n")
                    ?? (initial as? String) ?? (initial as? NSNumber)?.stringValue
                descriptions.append(.init(id: id, title: property["title"] as? String ?? id, kind: kind,
                                          required: required.contains(id), choices: choices, defaultValue: defaultValue))
            }
            externalID = nil
            display = .form(descriptions)
            properties = fields
        default:
            return nil
        }
    }

    func response(_ answer: InteractionResponse) throws -> Record {
        switch answer {
        case .cancelled: return ["action": "cancel"]
        case .confirmed(false): return ["action": "decline"]
        case .confirmed(true):
            if case .url = display { return ["action": "accept"] }
        case .value(let encoded):
            if case .form(let fields) = display, encoded.utf8.count <= 65_536,
               let content = (try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) as? Record,
               Set(content.keys).isSubset(of: Set(properties.keys)),
               fields.allSatisfy({ field in
                   guard let value = content[field.id] else { return !field.required }
                   return Self.validate(value, field: field, property: properties[field.id] ?? [:])
               }) {
                return ["action": "accept", "content": content]
            }
        }
        throw RuntimeFailure(.unsupportedInteraction,
                             String(localized: "回复内容不符合 ACP 请求的要求。", bundle: #bundle))
    }

    private static func choices(_ property: Record) -> [String] {
        if let values = property["enum"] as? [String] { return values }
        for key in ["oneOf", "anyOf"] {
            if let entries = property[key] as? [Record] {
                return entries.compactMap { $0["const"] as? String }
            }
        }
        return []
    }

    private static func validate(_ value: Any, field: RuntimeElicitationField, property: Record) -> Bool {
        func within(_ count: Int, min: String, max: String) -> Bool {
            count >= (property[min] as? Int ?? 0) && count <= (property[max] as? Int ?? Int.max)
        }
        switch field.kind {
        case .string:
            guard let text = value as? String,
                  within(text.unicodeScalars.count, min: "minLength", max: "maxLength"),
                  field.choices.isEmpty || field.choices.contains(text) else { return false }
            if let pattern = property["pattern"] as? String,
               text.range(of: pattern, options: .regularExpression) == nil { return false }
            switch property["format"] as? String {
            case "uri": return URL(string: text)?.scheme != nil
            case "email": return text.range(of: #"^[^\s@]+@[^\s@]+$"#, options: .regularExpression) != nil
            case "date-time": return ISO8601DateFormatter().date(from: text) != nil
            case "date":
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.date(from: text).map { formatter.string(from: $0) == text } ?? false
            default: return true
            }
        case .boolean:
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        case .integer, .number:
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            let decimal = number.doubleValue
            return decimal.isFinite && (field.kind != .integer || decimal.rounded() == decimal)
                && decimal >= (property["minimum"] as? Double ?? -.infinity)
                && decimal <= (property["maximum"] as? Double ?? .infinity)
        case .array:
            guard let entries = value as? [String], within(entries.count, min: "minItems", max: "maxItems") else { return false }
            return Set(entries).isSubset(of: Set(field.choices)) && Set(entries).count == entries.count
        }
    }
}
