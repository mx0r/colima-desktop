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
| image search | `GET /v1.44/images/search?term=T&limit=N` (Docker Hub, through the engine; snake_case keys) |
| pull | `POST /v1.44/images/create?fromImage=REPO&tag=TAG` (streamed JSON messages) |
| create | `POST /v1.44/containers/create[?name=N]` with `Image`, `Cmd`, `Env`, `ExposedPorts` and `HostConfig` (`PortBindings`, `Binds`, `RestartPolicy`, `PublishAllPorts`); 201 with `Id` and `Warnings` |

Errors arrive as `{"message": "…"}` and surface as `DockerError.api(status:message:)`.

## Images and new containers

- **Always send a tag with a pull.** With an empty `tag`, the engine pulls every tag of the repository
  ([spec](https://docs.docker.com/reference/api/engine/version/v1.44.yaml): "If empty when pulling an image,
  this causes all tags for the given image to be pulled"). `ImageReference.pullParameters` sends the digest,
  the tag, or `latest`.
- **Pull errors can arrive inside a 200 response.** Before the pull starts, a failure is an HTTP error
  (404 with `pull access denied …` for a missing repository). Once it has started, the engine reports the
  failure as a message with `error` / `errorDetail.message`; the client turns it into `DockerError.pullFailed`.
- **The pull stream** is one JSON object per line, lines end in CRLF. Layer messages carry an `id` and a
  status (`Pulling fs layer`, `Downloading` with `progressDetail.current/total`, `Download complete`,
  `Extracting`, `Pull complete`, `Already exists`); the first message carries the tag as `id`
  (`Pulling from library/x`) and is not a layer. Closing the connection cancels the pull.
- **Create, then pull on 404**, as `docker run` does: a missing image fails the create with
  `404 No such image`; the app pulls and creates again. "Pull the image even if it is already there"
  pulls first.
- **Tags are not in the Engine API.** The Docker Hub catalog reads them from Docker Hub's web API:
  `GET https://hub.docker.com/v2/namespaces/{namespace}/repositories/{name}/tags?page_size=50&ordering=last_updated`
  (`library` is the namespace of official images). Each tag lists its `images` with `os`, `architecture` and
  `variant`; entries with `os` `unknown` are build attestations. Docker Hub answers 429 when it rate-limits
  (it sends `x-ratelimit-*` headers) and 404 for an unknown repository. Other registries offer no search in
  the OCI distribution spec, so their images are typed by name.

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
