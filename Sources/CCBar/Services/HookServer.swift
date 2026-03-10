import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

final class HookServer {
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private let decoder = JSONDecoder()
    var onEvent: ((DetectedEvent) -> Void)?
    var getSessionsForStatus: (() -> [SessionInfo])?

    let host: String
    let port: Int

    init(host: String = "127.0.0.1", port: Int = 27182) {
        self.host = host
        self.port = port
    }

    func start() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let server = self

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HookHTTPHandler(server: server))
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)

        channel = try bootstrap.bind(host: host, port: port).wait()
    }

    func stop() {
        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()
        channel = nil
        group = nil
    }

    func handleHookEvent(_ data: Data) -> DetectedEvent? {
        guard let hookEvent = try? decoder.decode(HookEvent.self, from: data) else {
            return nil
        }
        return mapHookEvent(hookEvent)
    }

    private func mapHookEvent(_ hook: HookEvent) -> DetectedEvent? {
        guard let eventName = hook.hookEventName else { return nil }
        let cwd = hook.cwd
        let syntheticId = "hook-\(UUID().uuidString.prefix(8))"

        switch eventName {
        case "Stop", "SubagentStop":
            return .turnEnded(sessionId: hook.sessionId, durationMs: 0, cwd: cwd)
        case "PreToolUse":
            if let toolName = hook.toolName {
                if toolName == "AskUserQuestion" {
                    let question = AnyCodable.extractQuestionText(from: hook.toolInput)
                    return .askUserQuestion(
                        sessionId: hook.sessionId,
                        toolUseId: syntheticId,
                        questionText: question,
                        cwd: cwd
                    )
                }
                return .toolUseStarted(
                    sessionId: hook.sessionId,
                    toolUseId: syntheticId,
                    toolName: toolName,
                    cwd: cwd
                )
            }
            return nil
        case "PostToolUse":
            // Tool completed (approved, rejected, or error) — clears permission waiting
            return .toolUseCompleted(
                sessionId: hook.sessionId,
                toolUseId: syntheticId,
                cwd: cwd
            )
        case "UserPromptSubmit":
            return .userPrompt(sessionId: hook.sessionId, cwd: cwd)
        case "SessionEnd":
            return .sessionEnded(sessionId: hook.sessionId)
        case "Notification":
            switch hook.notificationType {
            case "permission_prompt":
                return .permissionWaiting(sessionId: hook.sessionId, cwd: cwd)
            default:
                // idle_prompt, auth_success, elicitation_dialog, etc.
                return .turnEnded(sessionId: hook.sessionId, durationMs: 0, cwd: cwd)
            }
        default:
            return nil
        }
    }
}

private final class HookHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let server: HookServer
    private let encoder = JSONEncoder()
    private var requestMethod: HTTPMethod?
    private var requestURI: String?
    private var bodyBuffer: ByteBuffer?

    init(server: HookServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)

        switch reqPart {
        case .head(let head):
            requestMethod = head.method
            requestURI = head.uri
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)

        case .body(var buf):
            bodyBuffer?.writeBuffer(&buf)

        case .end:
            handleRequest(context: context)
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        guard let method = requestMethod, let uri = requestURI else {
            sendResponse(context: context, status: .badRequest, body: "{\"error\":\"bad request\"}")
            return
        }

        switch (method, uri) {
        case (.POST, "/claude-event"):
            handleClaudeEvent(context: context)
        case (.GET, "/status"):
            handleStatus(context: context)
        default:
            sendResponse(context: context, status: .notFound, body: "{\"error\":\"not found\"}")
        }
    }

    private func handleClaudeEvent(context: ChannelHandlerContext) {
        guard let body = bodyBuffer, body.readableBytes > 0 else {
            sendResponse(context: context, status: .badRequest, body: "{\"error\":\"empty body\"}")
            return
        }

        let data = Data(body.readableBytesView)

        if let event = server.handleHookEvent(data) {
            server.onEvent?(event)
            sendResponse(context: context, status: .ok, body: "{\"status\":\"ok\"}")
        } else {
            sendResponse(context: context, status: .ok, body: "{\"status\":\"ok\",\"parsed\":false}")
        }
    }

    private func handleStatus(context: ChannelHandlerContext) {
        let sessions = server.getSessionsForStatus?() ?? []
        let waitingSessions = sessions.filter(\.isWaitingForInput)

        struct StatusResponse: Codable {
            let totalSessions: Int
            let waitingSessions: Int
            let sessions: [SessionStatusItem]
        }

        struct SessionStatusItem: Codable {
            let id: String
            let project: String
            let status: String
        }

        let items = waitingSessions.map { s in
            SessionStatusItem(id: s.id, project: s.projectName, status: s.status.rawValue)
        }

        let response = StatusResponse(
            totalSessions: sessions.count,
            waitingSessions: waitingSessions.count,
            sessions: items
        )

        let body: String
        if let data = try? encoder.encode(response),
           let json = String(data: data, encoding: .utf8) {
            body = json
        } else {
            body = "{\"totalSessions\":0,\"waitingSessions\":0,\"sessions\":[]}"
        }

        sendResponse(context: context, status: .ok, body: body)
    }

    private func sendResponse(context: ChannelHandlerContext, status: HTTPResponseStatus, body: String) {
        let byteCount = body.utf8.count
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(byteCount)")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: byteCount)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
