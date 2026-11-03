//! 結果DTOの直接的な失敗と、CLI/queueが使う操作完了判定。
use serde_json::Value;

pub(crate) fn has_direct_error(value: &Value) -> bool {
    value
        .get("error")
        .and_then(Value::as_str)
        .is_some_and(|s| !s.is_empty())
        || value
            .get("status")
            .and_then(Value::as_str)
            .is_some_and(|s| {
                matches!(
                    s,
                    "failed"
                        | "ambiguous"
                        | "unavailable"
                        | "conflict"
                        | "error"
                        | "restore_failed"
                        | "missing"
                )
            })
}

pub(crate) fn has_operation_errors(value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    if has_direct_error(value) {
        return true;
    }
    if let Some(result) = object.get("result") {
        if has_operation_errors(result) {
            return true;
        }
    }
    if object.contains_key("registryReady")
        && object.get("dryRun").and_then(Value::as_bool) != Some(true)
        && object.get("registryReady").and_then(Value::as_bool) != Some(true)
    {
        return true;
    }
    if object.contains_key("capacityKnown")
        && ["complete", "capacityKnown", "budgetSatisfied"]
            .iter()
            .any(|k| object.get(*k).and_then(Value::as_bool) != Some(true))
    {
        return true;
    }
    for key in ["items", "operations"] {
        if let Some(items) = object.get(key).and_then(Value::as_array) {
            if items.iter().any(has_operation_errors) {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn wire_failure_statuses_and_errors_are_direct_failures() {
        for status in [
            "failed",
            "ambiguous",
            "unavailable",
            "conflict",
            "error",
            "restore_failed",
            "missing",
        ] {
            assert!(has_direct_error(&json!({"status":status})));
        }
        assert!(has_direct_error(&json!({"error":"denied"})));
        for value in [
            json!({"error":""}),
            json!({"error":false}),
            json!({"status":"recycled"}),
            json!({"status":"already_absent"}),
            json!({"result":{"status":"failed"}}),
        ] {
            assert!(!has_direct_error(&value), "{value}");
        }
    }

    #[test]
    fn operation_completion_retains_readiness_capacity_and_nested_operations() {
        assert!(has_operation_errors(
            &json!({"operations":[{"result":{"items":[{"status":"ambiguous"}]}}]})
        ));
        assert!(has_operation_errors(
            &json!({"registryReady":false,"dryRun":false})
        ));
        assert!(!has_operation_errors(
            &json!({"registryReady":false,"dryRun":true})
        ));
        assert!(has_operation_errors(
            &json!({"capacityKnown":true,"complete":true,"budgetSatisfied":false})
        ));
        assert!(!has_operation_errors(
            &json!({"capacityKnown":true,"complete":true,"budgetSatisfied":true})
        ));
    }
}
