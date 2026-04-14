use axum::http::StatusCode;

#[derive(Debug, Clone, Copy)]
pub enum ErrorCode {
    BadRequest,
    NotFound,
    Internal,
    NotImplemented,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BadRequest => "BAD_REQUEST",
            Self::NotFound => "NOT_FOUND",

            Self::Internal => "INTERNAL",
            Self::NotImplemented => "NOT_IMPLEMENTED",
        }
    }

    pub fn http_status(self) -> StatusCode {
        match self {
            Self::BadRequest => StatusCode::BAD_REQUEST,
            Self::NotFound => StatusCode::NOT_FOUND,

            Self::Internal => StatusCode::INTERNAL_SERVER_ERROR,
            Self::NotImplemented => StatusCode::NOT_IMPLEMENTED,
        }
    }
}

pub fn rest_error(code: ErrorCode, message: impl Into<String>) -> (StatusCode, String) {
    (code.http_status(), message.into())
}
