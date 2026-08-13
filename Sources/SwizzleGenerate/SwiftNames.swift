import SwizzleCore

/// Turning database names into Swift names.
///
/// Small, and worth being deliberate about: the generator emits these into source
/// people read, and a rule that produces `Id` where everyone writes `ID`, or that
/// silently emits a keyword, is the kind of thing that makes generated code feel
/// foreign.
public enum SwiftNames {
    /// `user_accounts` → `UserAccounts`, for a type name.
    public static func typeName(_ raw: String) -> String {
        let joined = words(in: raw).map(capitalise).joined()
        return escapeIfNeeded(prefixIfNeeded(joined))
    }

    /// `created_at` → `createdAt`, for a property or parameter.
    public static func memberName(_ raw: String) -> String {
        let parts = words(in: raw)
        guard let first = parts.first else { return "_" }
        let joined = lowercase(first) + parts.dropFirst().map(capitalise).joined()
        return escapeIfNeeded(prefixIfNeeded(joined))
    }

    /// Splits on the separators databases actually use, and on case changes, so
    /// both `user_accounts` and `userAccounts` come out the same.
    static func words(in raw: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLower = false

        for character in raw {
            if character == "_" || character == "-" || character == " " || character == "." {
                if !current.isEmpty { words.append(current); current = "" }
                previousWasLower = false
                continue
            }
            if character.isUppercase, previousWasLower, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
            previousWasLower = character.isLowercase || character.isNumber
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Capitalises a word, keeping the initialisms people expect to see shouted.
    ///
    /// `id` → `ID` reads as native Swift; `Id` reads as generated.
    static func capitalise(_ word: String) -> String {
        if let known = initialisms[word.lowercased()] { return known }
        guard let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst()
    }

    static func lowercase(_ word: String) -> String {
        // A leading initialism stays lowercase in a member name — `id`, not `iD`.
        if initialisms[word.lowercased()] != nil { return word.lowercased() }
        guard let first = word.first else { return word }
        return String(first).lowercased() + word.dropFirst()
    }

    static let initialisms: [String: String] = [
        "id": "ID", "url": "URL", "uri": "URI", "uuid": "UUID",
        "api": "API", "http": "HTTP", "https": "HTTPS", "sql": "SQL",
        "json": "JSON", "html": "HTML", "ip": "IP", "db": "DB",
    ]

    /// A Swift identifier cannot start with a digit, and a column called `2fa`
    /// is a real thing people have.
    static func prefixIfNeeded(_ name: String) -> String {
        guard let first = name.first, first.isNumber else { return name }
        return "_" + name
    }

    /// Backticks a reserved word rather than mangling it, so the generated name
    /// still matches the column.
    static func escapeIfNeeded(_ name: String) -> String {
        reserved.contains(name) ? "`\(name)`" : name
    }

    static let reserved: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
        "func", "import", "init", "inout", "internal", "let", "open", "operator",
        "private", "protocol", "public", "rethrows", "static", "struct", "subscript",
        "typealias", "var", "break", "case", "continue", "default", "defer", "do",
        "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
        "switch", "where", "while", "as", "catch", "false", "is", "nil", "super",
        "self", "Self", "throw", "throws", "true", "try", "Any", "Protocol", "Type",
        "associativity", "convenience", "dynamic", "didSet", "final", "get", "infix",
        "indirect", "lazy", "left", "mutating", "none", "nonmutating", "optional",
        "override", "postfix", "precedence", "prefix", "required", "right", "set",
        "unowned", "weak", "willSet", "async", "await", "actor", "some", "each",
    ]
}

extension SwiftType {
    /// How this renders in generated source.
    public var sourceText: String {
        switch self {
        case .int64: "Int64"
        case .int32: "Int32"
        case .int16: "Int16"
        case .int8: "Int8"
        case .uint64: "UInt64"
        case .double: "Double"
        case .float: "Float"
        case .string: "String"
        case .bytes: "[UInt8]"
        case .bool: "Bool"
        // Exact numerics are text and stay text. Rendering these as `Double`
        // would lose the cents, which is the whole reason the type exists.
        case .decimalString: "String"
        case .date: "String"
        case .uuid: "String"
        case .json: "String"
        // **Not `[Element]`, and this is a deliberate step down.**
        //
        // The generator emitted `[String]` for a `text[]` column, and the result
        // did not compile: `SQLColumnValue` has an `Array` conformance only for
        // `[UInt8]`, so `[String](sqlValue:)` resolved against the bytes one and
        // failed with "requires the types 'String' and 'UInt8' be equivalent".
        // Caught by compiling the generated Postgres code, which nothing did
        // until this.
        //
        // `String` is what the driver actually produces — an array decodes to the
        // text Postgres itself prints, because `SQLValue` has no array case and
        // should not gain one for a type only Postgres can make. Emitting the
        // element type would be a nicer signature for something that cannot be
        // built.
        //
        // First-class arrays need `Array: SQLColumnValue where Element:
        // SQLColumnValue` in `SwizzleCore`, parsing the Postgres text form. That
        // is a real option and a separate decision; until then this is honest.
        case .array: "String"
        case .dynamic: "SQLValue"
        case .unresolved: "SQLValue"
        }
    }
}
