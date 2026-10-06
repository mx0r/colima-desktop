# Docker Engine API usage

The app talks HTTP/1.1 directly to the profile's Docker socket (`~/.colima/<profile>/docker.sock` by default).
It uses `NWConnection` with `NWEndpoint.unix(path:)`. Each request uses its own connection, as the Docker CLI
does for streams.

## Version

Requests use the `/v1.44` prefix. Docker 25 through 29 accept it (Docker 29.0–29.2 raised the minimum to 1.44,
29.3 lowered it back to 1.40; see the Docker 29 release notes). At connect time, `GET /version` checks that:

- the engine's `ApiVersion` is at least 1.44, otherwise the app reports an unsupported engine;
- `MinAPIVersion` is not above 1.44. A future engine with a higher minimum makes the app use that minimum.
  Decoders treat every field as optional.

## Endpoints

| Purpose | Request |
|---|---|
| version check | `GET /version` |
| engine facts | `GET /v1.44/info` |
| disk usage | `GET /v1.44/system/df` |
| containers | `GET /v1.44/containers/json?all=1` |
| details | `GET /v1.44/containers/{id}/json` |
| start / stop / restart | `POST /v1.44/containers/{id}/{start,stop,restart}` (304 = already in that state) |
| delete | `DELETE /v1.44/containers/{id}`, without `force` and `v`: the engine refuses running containers (409) and keeps volumes |
| logs | `GET /v1.44/containers/{id}/logs?follow=1&stdout=1&stderr=1&timestamps=1&tail=N[&since=T]` |
| events | `GET /v1.44/events?filters={"type":["container"]}` |
| exec | `POST /v1.44/containers/{id}/exec`, then `POST /v1.44/exec/{id}/start` (upgrade), `POST /v1.44/exec/{id}/resize?h=&w=`, `GET /v1.44/exec/{id}/json` |

Errors arrive as `{"message": "…"}` and surface as `DockerError.api(status:message:)`.

## Framing

- **Bodies:** `Content-Length`, `Transfer-Encoding: chunked` (the engine uses it for JSON), or read until close.
  `HTTPResponseParser` and `ChunkedDecoder` are incremental. Tests feed every payload whole, byte by byte and at
  random split points.
- **Logs:** non-TTY containers send a multiplexed stream (`application/vnd.docker.multiplexed-stream`).
  Every frame has an 8-byte header `[stream, 0, 0, 0, size (big-endian UInt32)]`, where stream 1 is stdout and
  2 is stderr. TTY containers send raw bytes (`application/vnd.docker.raw-stream`). Engines without these
  content types fall back to `Config.Tty` from inspect.
- **Timestamps:** lines start with an RFC 3339 timestamp (`timestamps=1`). The app parses and strips it, and
  the window can hide it.
- **Exec:** `exec/{id}/start` is sent with `Connection: Upgrade` and `Upgrade: tcp`. The engine answers
  `101 UPGRADED`, and the socket then carries raw terminal bytes in both directions (`Tty: true`, no
  multiplexing). Bytes that arrive together with the response head are the first output bytes.
