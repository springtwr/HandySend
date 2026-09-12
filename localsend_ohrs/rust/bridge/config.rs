//! 配置 JSON 字段解析辅助。
//!
//! 区分两种情形：字段缺失 → 使用默认值（合法的可选字段语义）；
//! 字段存在但类型/取值不符 → 返回 [`BridgeError::InvalidArgument`]
//! （调用方的拼写或类型错误应快速失败，而非静默回退默认值）。

use serde_json::Value;

use super::event::BridgeError;

fn type_error(key: &str, v: &Value) -> BridgeError {
    BridgeError::InvalidArgument(format!("配置字段 {key} 类型不符: {v}"))
}

/// 字符串字段；缺失用默认值，存在但非字符串报错。
pub fn str_field(config: &Value, key: &str, default: &str) -> Result<String, BridgeError> {
    match &config[key] {
        Value::Null => Ok(default.to_string()),
        Value::String(s) => Ok(s.clone()),
        v => Err(type_error(key, v)),
    }
}

/// 可选字符串字段；缺失为 None，存在但非字符串报错。
pub fn opt_str_field(config: &Value, key: &str) -> Result<Option<String>, BridgeError> {
    match &config[key] {
        Value::Null => Ok(None),
        Value::String(s) => Ok(Some(s.clone())),
        v => Err(type_error(key, v)),
    }
}

/// 布尔字段；缺失用默认值，存在但非布尔报错。
pub fn bool_field(config: &Value, key: &str, default: bool) -> Result<bool, BridgeError> {
    match &config[key] {
        Value::Null => Ok(default),
        Value::Bool(b) => Ok(*b),
        v => Err(type_error(key, v)),
    }
}

/// u16 字段；缺失用默认值，存在但超出 u16 范围报错（而非静默截断）。
pub fn u16_field(config: &Value, key: &str, default: u16) -> Result<u16, BridgeError> {
    match &config[key] {
        Value::Null => Ok(default),
        Value::Number(n) => match n.as_u64() {
            Some(v) if v <= u16::MAX as u64 => Ok(v as u16),
            _ => Err(type_error(key, &config[key])),
        },
        v => Err(type_error(key, v)),
    }
}

/// 必填 u16 字段；缺失或超出 u16 范围报错。
pub fn req_u16_field(config: &Value, key: &str) -> Result<u16, BridgeError> {
    if config[key].is_null() {
        return Err(BridgeError::InvalidArgument(format!("配置字段 {key} 缺失")));
    }
    u16_field(config, key, 0)
}

/// 必填字符串字段；缺失或非字符串报错。
pub fn req_str_field(config: &Value, key: &str) -> Result<String, BridgeError> {
    if config[key].is_null() {
        return Err(BridgeError::InvalidArgument(format!("配置字段 {key} 缺失")));
    }
    str_field(config, key, "")
}

/// 可选无符号整数字段；缺失用默认值，存在但非无符号整数报错。
pub fn opt_u64_field(config: &Value, key: &str, default: u64) -> Result<u64, BridgeError> {
    match &config[key] {
        Value::Null => Ok(default),
        Value::Number(n) => n.as_u64().ok_or_else(|| type_error(key, &config[key])),
        v => Err(type_error(key, v)),
    }
}

/// 可选字符串数组字段；缺失为 None，存在但非数组或含非字符串元素报错。
pub fn opt_str_array_field(config: &Value, key: &str) -> Result<Option<Vec<String>>, BridgeError> {
    match &config[key] {
        Value::Null => Ok(None),
        Value::Array(arr) => {
            let mut out = Vec::with_capacity(arr.len());
            for v in arr {
                match v.as_str() {
                    Some(s) => out.push(s.to_string()),
                    None => return Err(type_error(key, v)),
                }
            }
            Ok(Some(out))
        }
        v => Err(type_error(key, v)),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn test_str_field_missing_uses_default() {
        let config = json!({});
        assert_eq!(
            str_field(&config, "alias", "HarmonyOS").unwrap(),
            "HarmonyOS"
        );
    }

    #[test]
    fn test_str_field_wrong_type_errors() {
        let config = json!({"alias": 42});
        assert!(str_field(&config, "alias", "x").is_err());
    }

    #[test]
    fn test_bool_field() {
        let config = json!({"a": true});
        assert!(bool_field(&config, "a", false).unwrap());
        assert!(!bool_field(&config, "b", false).unwrap());
        assert!(bool_field(&config, "a", true).is_ok());
        let bad = json!({"a": "yes"});
        assert!(bool_field(&bad, "a", false).is_err());
    }

    #[test]
    fn test_u16_field_range() {
        let config = json!({"port": 53317});
        assert_eq!(u16_field(&config, "port", 1).unwrap(), 53317);
        assert_eq!(u16_field(&config, "missing", 53317).unwrap(), 53317);
        // 超出 u16 范围应报错而非静默截断
        let over = json!({"port": 70000});
        assert!(u16_field(&over, "port", 1).is_err());
        let bad = json!({"port": "53317"});
        assert!(u16_field(&bad, "port", 1).is_err());
    }

    #[test]
    fn test_req_fields() {
        let config = json!({"ip": "192.168.1.5", "port": 53317});
        assert_eq!(req_str_field(&config, "ip").unwrap(), "192.168.1.5");
        assert_eq!(req_u16_field(&config, "port").unwrap(), 53317);
        assert!(req_str_field(&config, "missing").is_err());
        assert!(req_u16_field(&config, "missing").is_err());
    }

    #[test]
    fn test_opt_fields() {
        let config = json!({"pin": "1234", "list": ["a", "b"], "n": 3000});
        assert_eq!(opt_str_field(&config, "pin").unwrap().unwrap(), "1234");
        assert!(opt_str_field(&config, "none").unwrap().is_none());
        assert_eq!(
            opt_str_array_field(&config, "list").unwrap().unwrap(),
            vec!["a".to_string(), "b".to_string()]
        );
        assert_eq!(opt_u64_field(&config, "n", 1).unwrap(), 3000);
        // 数组含非字符串元素应报错
        let bad = json!({"list": ["a", 1]});
        assert!(opt_str_array_field(&bad, "list").is_err());
    }
}
