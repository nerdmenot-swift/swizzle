# Finds every place a mutation can be applied, skipping the places where one
# would mean nothing.
#
# Emits one candidate per line:  <line>\t<column>\t<width>\t<replacement>\t<label>
#
# ## Why this is not a grep
#
# The first version of the sweep matched operators anywhere on a line, and 178 of
# its 184 "survivors" were noise: operators inside string literals, inside doc
# comments, and inside the emitter's own generated-code templates. Changing `>`
# to `>=` inside a comment is not a test gap, it is a typo nobody made — and a
# report that is 97% noise gets skimmed once and never opened again.
#
# So string literals and comments are masked out before operators are located.
# The mask is same-width, so a position found in the masked line is the same
# position in the real one, and the replacement lands exactly where it should.

function mask(text,   out, i, char, next_char, in_string, in_line_comment, escaped) {
    out = ""
    in_string = 0
    in_line_comment = 0
    escaped = 0

    for (i = 1; i <= length(text); i++) {
        char = substr(text, i, 1)
        next_char = (i < length(text)) ? substr(text, i + 1, 1) : ""

        if (in_line_comment) { out = out " "; continue }

        if (in_string) {
            out = out " "
            if (escaped)            { escaped = 0 }
            else if (char == "\\")  { escaped = 1 }
            else if (char == "\"")  { in_string = 0 }
            continue
        }

        if (char == "\"")                    { in_string = 1; out = out " "; continue }
        if (char == "/" && next_char == "/")  { in_line_comment = 1; out = out " "; continue }

        out = out char
    }
    return out
}

BEGIN {
    # Two-character operators first: finding `>` inside `>=` and rewriting it
    # would produce `>==`, which is a compile error and a wasted build.
    n = 0
    op[++n] = ">=";  rep[n] = "> ";   label[n] = ">= becomes >"
    op[++n] = "<=";  rep[n] = "< ";   label[n] = "<= becomes <"
    op[++n] = "==";  rep[n] = "!=";   label[n] = "== becomes !="
    op[++n] = "!=";  rep[n] = "==";   label[n] = "!= becomes =="
    op[++n] = "&&";  rep[n] = "||";   label[n] = "and becomes or"
    op[++n] = "||";  rep[n] = "&&";   label[n] = "or becomes and"
    count = n
}

{
    masked = mask($0)

    # Block comments span lines, so they are tracked across records rather than
    # inside `mask`.
    if (in_block) {
        if (index($0, "*/") > 0) in_block = 0
        next
    }
    if (index(masked, "/*") > 0) {
        if (index($0, "*/") == 0) in_block = 1
        next
    }

    for (k = 1; k <= count; k++) {
        start = 1
        while ((position = index(substr(masked, start), op[k])) > 0) {
            column = start + position - 1

            # A two-character operator that is really part of a three-character
            # one (`>=` inside `>>=`, `==` inside `===`) is left alone.
            before = (column > 1) ? substr(masked, column - 1, 1) : " "
            after = substr(masked, column + length(op[k]), 1)
            if (before !~ /[<>=!&|]/ && after !~ /[<>=!&|]/) {
                print NR "\t" column "\t" length(op[k]) "\t" rep[k] "\t" label[k]
            }
            start = column + length(op[k])
        }
    }
}

# Single-character comparisons, handled separately so the two-character forms
# above have already been excluded by the neighbour check.
{
    if (in_block) next
    masked2 = mask($0)
    split("> <", singles, " ")
    single_rep[">"] = ">="; single_label[">"] = "> becomes >="
    single_rep["<"] = "<="; single_label["<"] = "< becomes <="

    for (s = 1; s <= 2; s++) {
        ch = singles[s]
        start = 1
        while ((position = index(substr(masked2, start), ch)) > 0) {
            column = start + position - 1
            before = (column > 1) ? substr(masked2, column - 1, 1) : " "
            after = substr(masked2, column + 1, 1)
            # Not part of `>=`, `<=`, `->`, `<<`, `>>`, and not a generic
            # bracket: `Array<String>` is not a comparison, and mutating it is a
            # guaranteed compile error.
            if (before !~ /[<>=!\-]/ && after !~ /[<>=!]/ && before == " " && after == " ") {
                print NR "\t" column "\t1\t" single_rep[ch] "\t" single_label[ch]
            }
            start = column + 1
        }
    }
}
