use serde::{Deserialize, Serialize};
use worker::*;

const MAX_SIGNAL_BYTES: usize = 256 * 1024;

#[derive(Debug, Deserialize)]
struct SignalQuery {
    identifier: String,
    role: String,
    #[serde(rename = "clientIdentifier")]
    client_identifier: Option<String>,
    #[serde(rename = "hostToken")]
    host_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct PresenceQuery {
    identifier: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct SocketAttachment {
    role: String,
    authenticated: bool,
    attempts: u8,
    client_identifier: Option<String>,
    host_token: Option<String>,
}

#[event(fetch, respond_with_errors)]
pub async fn main(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    if req.path() == "/health" {
        return Response::from_json(&serde_json::json!({
            "ok": true,
            "service": "rtc-transfer-signaling"
        }));
    }
    if req.path() == "/presence" {
        let query: PresenceQuery = req.query()?;
        validate_identifier(&query.identifier)?;
        let namespace = env.durable_object("SIGNAL_ROOMS")?;
        let stub = namespace.id_from_name(&query.identifier)?.get_stub()?;
        return stub.fetch_with_request(req).await;
    }
    if req.path() != "/signal" {
        return Response::error("Not found", 404);
    }
    if !is_websocket_upgrade(&req)? {
        return Response::error("Expected WebSocket upgrade", 426);
    }

    let query: SignalQuery = req
        .query()
        .map_err(|_| Error::RustError("Invalid query parameters".into()))?;
    validate_query(&query)?;
    let room_name = query.identifier;
    let namespace = env.durable_object("SIGNAL_ROOMS")?;
    let stub = namespace.id_from_name(&room_name)?.get_stub()?;
    stub.fetch_with_request(req).await
}

fn is_websocket_upgrade(req: &Request) -> Result<bool> {
    Ok(req
        .headers()
        .get("Upgrade")?
        .is_some_and(|value| value.eq_ignore_ascii_case("websocket")))
}

fn validate_query(query: &SignalQuery) -> Result<()> {
    validate_identifier(&query.identifier)?;
    if let Some(client_identifier) = &query.client_identifier {
        validate_identifier(client_identifier)?;
    }
    let owner_role = matches!(query.role.as_str(), "host" | "presence");
    let role_valid = owner_role || query.role == "peer";
    let client_valid = query.role != "peer" || query.client_identifier.is_some();
    let host_token_valid = if owner_role {
        query.host_token.as_ref().is_some_and(|token| {
            token.len() == 32 && token.bytes().all(|byte| byte.is_ascii_alphanumeric())
        })
    } else {
        true
    };
    if role_valid && client_valid && host_token_valid {
        Ok(())
    } else {
        Err(Error::RustError("Invalid role or client identifier".into()))
    }
}

fn validate_identifier(identifier: &str) -> Result<()> {
    let valid = (3..=64).contains(&identifier.len())
        && identifier
            .bytes()
            .all(|value| value.is_ascii_alphanumeric() || matches!(value, b'-' | b'_'));
    if valid {
        Ok(())
    } else {
        Err(Error::RustError("Invalid identifier".into()))
    }
}

#[durable_object]
pub struct SignalRoom {
    state: State,
}

impl DurableObject for SignalRoom {
    fn new(state: State, _env: Env) -> Self {
        Self { state }
    }

    async fn fetch(&self, req: Request) -> Result<Response> {
        if req.path() == "/presence" {
            return Response::from_json(&serde_json::json!({
                "online": !self.state.get_websockets_with_tag("host").is_empty()
            }));
        }
        if !is_websocket_upgrade(&req)? {
            return Response::error("Expected WebSocket upgrade", 426);
        }
        let query: SignalQuery = req.query()?;
        validate_query(&query)?;
        if matches!(query.role.as_str(), "host" | "presence") {
            for tag in ["host", "presence"] {
                for existing in self.state.get_websockets_with_tag(tag) {
                    let attachment = existing.deserialize_attachment::<SocketAttachment>()?;
                    let same_owner = attachment
                        .as_ref()
                        .and_then(|value| value.host_token.as_ref())
                        == query.host_token.as_ref();
                    if !same_owner {
                        return Response::error("A different device owns this identifier", 409);
                    }
                }
            }
            for existing in self.state.get_websockets_with_tag(&query.role) {
                let attachment = existing.deserialize_attachment::<SocketAttachment>()?;
                let can_replace = attachment
                    .as_ref()
                    .and_then(|value| value.host_token.as_ref())
                    .is_none_or(|token| Some(token) == query.host_token.as_ref());
                if !can_replace {
                    return Response::error("A different host owns this identifier", 409);
                }
                let _ = existing.close(Some(4000), Some("Replaced by a newer connection"));
            }
        } else {
            if !self.state.get_websockets_with_tag("peer").is_empty() {
                return Response::error("A peer is already authenticating or connected", 409);
            }
            if self.state.get_websockets_with_tag("host").is_empty() {
                return Response::error("Identifier is incorrect or host is offline", 404);
            }
        }

        let pair = WebSocketPair::new()?;
        pair.server.serialize_attachment(&SocketAttachment {
            role: query.role.clone(),
            authenticated: query.role != "peer",
            attempts: 0,
            client_identifier: query.client_identifier,
            host_token: query.host_token,
        })?;
        self.state
            .accept_websocket_with_tags(&pair.server, &[query.role.as_str()]);

        pair.server.send_with_str(
            &serde_json::json!({
                "type": "ready",
                "role": query.role
            })
            .to_string(),
        )?;
        Response::from_websocket(pair.client)
    }

    async fn websocket_message(
        &self,
        ws: WebSocket,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        let WebSocketIncomingMessage::String(text) = message else {
            return ws.send_with_str(
                r#"{"type":"error","message":"Binary signaling is not supported"}"#,
            );
        };
        if text.len() > MAX_SIGNAL_BYTES {
            return ws.close(Some(1009), Some("Signal message too large"));
        }
        let value: serde_json::Value = serde_json::from_str(&text)
            .map_err(|_| Error::RustError("Invalid signaling JSON".into()))?;
        let mut sender: SocketAttachment = ws
            .deserialize_attachment()?
            .ok_or_else(|| Error::RustError("Missing socket attachment".into()))?;
        let message_type = value
            .get("type")
            .and_then(|item| item.as_str())
            .unwrap_or("");

        if sender.role == "presence" {
            return Ok(());
        }

        if sender.role == "peer" && !sender.authenticated {
            if message_type != "authenticate" {
                return ws.send_with_str(
                    r#"{"type":"auth_failed","message":"Authentication required"}"#,
                );
            }
            let totp = value
                .get("totp")
                .and_then(|item| item.as_str())
                .unwrap_or("");
            if totp.len() != 6 || !totp.bytes().all(|byte| byte.is_ascii_digit()) {
                return ws
                    .send_with_str(r#"{"type":"auth_failed","message":"Invalid TOTP format"}"#);
            }
            sender.attempts = sender.attempts.saturating_add(1);
            ws.serialize_attachment(&sender)?;
            if sender.attempts > 5 {
                ws.send_with_str(r#"{"type":"auth_failed","message":"Too many attempts"}"#)?;
                return ws.close(Some(1008), Some("Too many authentication attempts"));
            }
            let challenge = serde_json::json!({
                "type": "auth_request",
                "totp": totp,
                "peerIdentifier": sender.client_identifier
            });
            for host in self.state.get_websockets_with_tag("host") {
                host.send_with_str(&challenge.to_string())?;
            }
            return Ok(());
        }

        if sender.role == "host" && message_type == "auth_result" {
            let approved = value
                .get("ok")
                .and_then(|item| item.as_bool())
                .unwrap_or(false);
            for peer in self.state.get_websockets_with_tag("peer") {
                let Some(mut attachment) = peer.deserialize_attachment::<SocketAttachment>()?
                else {
                    continue;
                };
                if attachment.authenticated {
                    continue;
                }
                if approved {
                    attachment.authenticated = true;
                    peer.serialize_attachment(&attachment)?;
                    peer.send_with_str(r#"{"type":"auth_ok"}"#)?;
                    ws.send_with_str(r#"{"type":"peer_joined"}"#)?;
                } else {
                    peer.send_with_str(r#"{"type":"auth_failed"}"#)?;
                }
            }
            return Ok(());
        }

        if sender.role == "peer" && sender.authenticated {
            for host in self.state.get_websockets_with_tag("host") {
                host.send_with_str(&text)?;
            }
        } else if sender.role == "host" {
            for peer in self.state.get_websockets_with_tag("peer") {
                let authenticated = peer
                    .deserialize_attachment::<SocketAttachment>()?
                    .is_some_and(|attachment| attachment.authenticated);
                if authenticated {
                    peer.send_with_str(&text)?;
                }
            }
        }
        Ok(())
    }

    async fn websocket_close(
        &self,
        ws: WebSocket,
        _code: usize,
        _reason: String,
        _was_clean: bool,
    ) -> Result<()> {
        let Some(attachment) = ws.deserialize_attachment::<SocketAttachment>()? else {
            return Ok(());
        };
        if !attachment.authenticated {
            return Ok(());
        }
        let target_tag = match attachment.role.as_str() {
            "host" => "peer",
            "peer" => "host",
            _ => return Ok(()),
        };
        for target in self.state.get_websockets_with_tag(target_tag) {
            let _ = target.send_with_str(r#"{"type":"peer_left"}"#);
        }
        Ok(())
    }

    async fn websocket_error(&self, _ws: WebSocket, error: Error) -> Result<()> {
        console_error!("SignalRoom WebSocket error: {error}");
        Ok(())
    }
}
