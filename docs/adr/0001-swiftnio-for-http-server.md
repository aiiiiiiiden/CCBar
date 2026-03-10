# ADR-0001: SwiftNIO for HTTP Server

## Status

Accepted

## Context

CCBar needs an embedded HTTP server to receive hook events from Claude Code via POST requests. The server listens on port 27182 and handles two routes: `POST /claude-event` for incoming hook payloads and `GET /status` for health checks.

Requirements:
- Lightweight embedded HTTP server (no full web framework needed)
- macOS-only, no cross-platform requirement
- Minimal external dependencies
- Low latency for event delivery
- Must coexist with AppKit's main run loop

## Decision

Use Apple's SwiftNIO (`swift-nio` package) as the HTTP server foundation, specifically the `NIOCore`, `NIOPosix`, and `NIOHTTP1` modules.

## Consequences

**Positive:**
- SwiftNIO is maintained by Apple with long-term support
- Minimal footprint: only three modules needed (NIOCore, NIOPosix, NIOHTTP1)
- Non-blocking event loop integrates well with the macOS app lifecycle
- No additional transitive dependencies beyond the swift-nio package
- Battle-tested in production by the Swift server ecosystem

**Negative:**
- Requires `@unchecked Sendable` on the NIO channel handler due to framework constraints
- More boilerplate than a higher-level framework (manual HTTP parsing, channel pipeline setup)
- Learning curve for developers unfamiliar with NIO's channel/handler model

## Alternatives Considered

**Vapor**: Full-featured web framework built on SwiftNIO. Rejected because it brings significant additional dependencies (Vapor, Routing, etc.) that are unnecessary for two simple routes. The framework overhead is disproportionate to the use case.

**Raw BSD Sockets**: Using POSIX socket APIs directly. Rejected because it would require implementing HTTP parsing from scratch, increasing maintenance burden and bug surface without meaningful benefits.

**Foundation URLSession (server mode)**: Foundation does not provide a built-in HTTP server. Would require a third-party wrapper or manual implementation on top of Network.framework.

**Network.framework (NWListener)**: Apple's modern networking framework. Rejected because it lacks built-in HTTP protocol support, requiring manual HTTP request/response parsing similar to raw sockets.
