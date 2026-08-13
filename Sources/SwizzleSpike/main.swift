import Swizzle

func show(_ label: String, _ result: (sql: String, bindings: [SQLValue])) {
    print("── \(label)")
    print("   \(result.sql)")
    print("   bindings: \(result.bindings.count)\n")
}

show("q01 trivial", q01_trivial())
show("q02 literal-heavy", q02_literalHeavy())
show("q03 join", q03_join())
show("q04 4-table aggregate (&&)", q04_fourTableAggregate())
show("q05 4-table aggregate (and())", q05_fourTableAggregate_functionForm())
show("q06 correlated EXISTS", q06_correlatedExists())
show("q07 aliased self-join", q07_aliasedSelfJoin())
show("q09 pack width 8", q09_packWidth8())
show("q10 pack width 16", q10_packWidth16())
show("q11 postgres DISTINCT ON", q11_postgresOnlyDistinctOn())

print("── q12 dialect divergence")
for (sql, bindings) in q12_sqliteAndMysqlRenderDifferently() {
    print("   \(sql)  [\(bindings.count) bindings]")
}
print()

print("── q13 capability-gated inserts")
for line in q13_capabilityGatedInserts() {
    print("   \(line)")
}
print()

// Prove the projection pack actually types the decoded row.
let row = SQLRow(values: [.int(7), .text("Ada")])
let decoded: (Int64, String) = try pg.select(users.id, users.name).from(users).decode(row)
print("── decoded tuple: \(decoded)  (statically (Int64, String))")
