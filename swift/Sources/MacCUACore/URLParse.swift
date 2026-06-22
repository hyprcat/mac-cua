import Foundation

// Minimal port of the slice of Python's urllib.parse used by pruning's URL
// shortener: urlparse → (scheme, netloc, path, params, query, fragment) and
// urlunparse to rebuild. Only the behaviour exercised by shorten_urls is
// reproduced (http/https URLs with optional query/fragment); good enough to be
// byte-compatible with CPython for the shapes that flow through pruning.

struct ParsedURL {
    var scheme: String
    var netloc: String
    var path: String
    var params: String
    var query: String
    var fragment: String

    /// Parse like `urllib.parse.urlparse`. Returns nil only for inputs that
    /// Python would also fail to handle meaningfully (never, in practice — kept
    /// optional to mirror the Python try/except guard around urlparse).
    init?(_ url: String) {
        var rest = Substring(url)

        // Fragment: split on the first '#'.
        var fragment = ""
        if let hashIdx = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hashIdx)...])
            rest = rest[..<hashIdx]
        }

        // Scheme: leading "<scheme>://"-style. Python only treats text before
        // the first ':' as a scheme when it's a valid scheme token; for our
        // inputs (http/https) this is sufficient.
        var scheme = ""
        if let colonIdx = rest.firstIndex(of: ":") {
            let candidate = rest[..<colonIdx]
            if !candidate.isEmpty,
               candidate.first!.isLetter,
               candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) {
                scheme = String(candidate).lowercased()
                rest = rest[rest.index(after: colonIdx)...]
            }
        }

        // Netloc: present only when the remainder starts with "//".
        var netloc = ""
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            // netloc runs until the next '/', '?', or '#' (fragment already removed).
            let netEnd = rest.firstIndex { $0 == "/" || $0 == "?" }
            if let netEnd {
                netloc = String(rest[..<netEnd])
                rest = rest[netEnd...]
            } else {
                netloc = String(rest)
                rest = Substring("")
            }
        }

        // Query: split on the first '?'.
        var query = ""
        if let qIdx = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: qIdx)...])
            rest = rest[..<qIdx]
        }

        // Params: text after the last ';' in the final path segment.
        var params = ""
        var path = String(rest)
        if let semiIdx = path.lastIndex(of: ";"),
           let lastSlash = path.lastIndex(of: "/") {
            if semiIdx > lastSlash {
                params = String(path[path.index(after: semiIdx)...])
                path = String(path[..<semiIdx])
            }
        } else if let semiIdx = path.lastIndex(of: ";"), !path.contains("/") {
            params = String(path[path.index(after: semiIdx)...])
            path = String(path[..<semiIdx])
        }

        self.scheme = scheme
        self.netloc = netloc
        self.path = path
        self.params = params
        self.query = query
        self.fragment = fragment
    }

    /// Rebuild like `urllib.parse.urlunparse`, substituting the supplied query
    /// and fragment (the shortener passes "" to drop them).
    func unparse(query: String, fragment: String) -> String {
        var url = ""

        if !netloc.isEmpty || (!scheme.isEmpty && path.hasPrefix("//")) {
            // urlunparse: when netloc present (or scheme set with //-path), emit
            // "//netloc" before path.
            var p = path
            if !p.isEmpty, !p.hasPrefix("/"), !netloc.isEmpty {
                p = "/" + p
            }
            url = "//" + netloc + p
        } else {
            url = path
        }

        if !scheme.isEmpty {
            url = scheme + ":" + url
        }
        if !params.isEmpty {
            url += ";" + params
        }
        if !query.isEmpty {
            url += "?" + query
        }
        if !fragment.isEmpty {
            url += "#" + fragment
        }
        return url
    }
}
