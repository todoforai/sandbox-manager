use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::service::errors::ErrorCode;
use crate::service::types::CreateSandboxRequest;

#[derive(Debug, Deserialize)]
pub struct NoiseRequest {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub payload: Value,
}

#[derive(Debug, Serialize)]
pub struct NoiseResponse {
    pub id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<NoiseError>,
}

#[derive(Debug, Serialize)]
pub struct NoiseError {
    pub code: &'static str,
    pub message: String,
}

#[derive(Debug, Deserialize)]
pub struct IdPayload {
    pub id: String,
}

#[derive(Debug, Deserialize)]
pub struct ListPayload {
    pub user_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CreateTemplateRequest {
    pub name: String,
    pub kernel_path: String,
    pub rootfs_path: String,
    pub boot_args: Option<String>,
    pub description: Option<String>,
    pub packages: Option<Vec<String>>,
}

pub fn ok<T: Serialize>(id: String, result: T) -> NoiseResponse {
    NoiseResponse {
        id,
        ok: true,
        result: Some(serde_json::to_value(result).unwrap_or(Value::Null)),
        error: None,
    }
}

pub fn err(id: String, code: ErrorCode, message: impl Into<String>) -> NoiseResponse {
    NoiseResponse {
        id,
        ok: false,
        result: None,
        error: Some(NoiseError {
            code: code.as_str(),
            message: message.into(),
        }),
    }
}

pub fn parse<T: for<'de> Deserialize<'de>>(value: Value) -> Result<T, String> {
    serde_json::from_value(value).map_err(|e| e.to_string())
}

pub type CreateSandboxPayload = CreateSandboxRequest;
