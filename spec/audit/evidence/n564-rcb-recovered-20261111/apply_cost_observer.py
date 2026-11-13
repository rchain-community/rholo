#!/usr/bin/env python3
"""Diagnostic stdout observer for exact incident source; never an acceptance fix."""
import hashlib
import json
import pathlib

path = pathlib.Path("rholang/src/accounting.rs")
original = path.read_bytes()
source = original.decode()
anchors = [
    ("    pub fn set(&self, cost: Cost) {\n        self.value.store(cost.value, Ordering::SeqCst);",
     "    pub fn set(&self, cost: Cost) {\n        if std::env::var_os(\"OMEGA_RCB_COST_TRACE\").is_some() {\n            eprintln!(\"OMEGA_M26_SET value={} operation={:?}\", cost.value, cost.operation);\n        }\n        self.value.store(cost.value, Ordering::SeqCst);"),
    ("            Ok(prev) => {\n                self.total.fetch_add(amount_value, Ordering::SeqCst);",
     "            Ok(prev) => {\n                if std::env::var_os(\"OMEGA_RCB_COST_TRACE\").is_some() {\n                    eprintln!(\"OMEGA_M26_CHARGE value={} operation={:?} previous={} remaining={}\", amount_value, amount.operation, prev, (prev - amount_value).max(0));\n                }\n                self.total.fetch_add(amount_value, Ordering::SeqCst);"),
]
for before, after in anchors:
    assert source.count(before) == 1, "observer anchor must be unique on pinned incident source"
    source = source.replace(before, after)
path.write_text(source)
print(json.dumps({"file": str(path), "original_sha256": hashlib.sha256(original).hexdigest(),
                  "observed_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                  "change": "environment-gated logging only; cost arithmetic and validation unchanged"}))
