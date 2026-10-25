import Foundation
import macSCPCore

/// A blank secret means unchanged only for an existing login of the same
/// protocol and authentication method. Never read or fabricate a secret to
/// validate a metadata edit.
enum LoginSetEditorValidation {
    static func canSave(name: String, kind: ConnectionKind, values: FieldValues, existing: LoginSet?) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let descriptor = BackendDescriptor.descriptor(for: kind)
        let preservesSecret: Bool
        if let existing, existing.kind == kind {
            let edited = descriptor.loginSet(id: existing.id, name: name, from: values)
            preservesSecret = edited.authKind == existing.authKind
        } else { preservesSecret = false }
        return descriptor.credentialSchema.missingRequiredFields(
            in: values, namespace: descriptor.fieldNamespace
        ).allSatisfy { preservesSecret && $0.isSecret }
    }
}
