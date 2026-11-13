import Foundation
import Testing
@testable import ORB

@Suite("MCP discovery cancellation", .serialized)
struct MCPDiscoveryCancellationTests {
    private static var node: String? {
        ([ProcessInfo.processInfo.environment["NODE_BINARY"]].compactMap { $0 } + ["/opt/homebrew/bin/node", "/usr/local/bin/node"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func fixture(method: String, errors: Bool = false, exits: Bool = false) throws -> (MCPServerConfig, MCPConnection) {
        let script = try #require(Bundle.module.url(forResource: "orb-mcp-discovery-fixture", withExtension: "mjs", subdirectory: "Fixtures"))
        let config = MCPServerConfig(name: "discovery-fixture", command: try #require(Self.node),
                                     args: [script.path, method, exits ? "exit" : (errors ? "error" : "hold")])
        return (config, MCPConnection(config: config, secretStore: InMemoryCredentialStore(), requestTimeout: .seconds(8)))
    }

    private func waitForDiscovery(_ method: String, connection: MCPConnection) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await connection.isRunning,
               let state = try? await connection.callTool(name: "state", arguments: .object([:])), state.content == method { return }
            await Task.yield()
        }
        throw MCPError.transport("Fixture did not reach held discovery request")
    }

    @Test("M02: cancelling optional discovery must not report connect success",
          .enabled(if: Self.node != nil, "requires Node"), arguments: ["resources/list", "prompts/list"])
    func directCancellation(method: String) async throws {
        let (_, connection) = try fixture(method: method)
        let startup = MCPHeldTask<Result<Void, Error>> {
            do { try await connection.connect(); return .success(()) }
            catch { return .failure(error) }
        }
        do {
            try await waitForDiscovery(method, connection: connection)
            startup.cancel()
            let result = try await startup.value()
            switch result {
            case .success: Issue.record("Cancelled discovery reported successful connection")
            case .failure(let error): #expect(error is CancellationError)
            }
            #expect(await connection.isReady == false)
            #expect(await connection.isRunning == false)
            #expect(await connection.tools.isEmpty)
            await connection.shutdown()
        } catch {
            startup.cancel()
            await connection.shutdown()
            await startup.drain()
            throw error
        }
    }

    @Test("M02: cancelled registry startup must not publish a partial connection",
          .enabled(if: Self.node != nil, "requires Node"), arguments: ["resources/list", "prompts/list"])
    func registryCancellation(method: String) async throws {
        let (config, connection) = try fixture(method: method)
        let registry = MCPRegistry(configProvider: { [config] }, connectionFactory: { _ in connection })
        let startup = MCPHeldTask { await registry.startEnabledServers() }
        do {
            try await waitForDiscovery(method, connection: connection)
            startup.cancel()
            try await startup.value()
            #expect(await connection.isRunning == false)
            #expect(await registry.status().allSatisfy { !$0.connected && $0.error == nil })
            // A fresh inventory request now retries cancelled first startup.
            // Inspect the cancelled connection itself without initiating retry.
            #expect(await connection.tools.isEmpty)
            await registry.shutdownAll()
        } catch {
            startup.cancel()
            await connection.shutdown()
            await startup.drain()
            let cleanup = MCPHeldTask { await registry.shutdownAll() }
            await cleanup.drain()
            cleanup.cancel()
            throw error
        }
    }

    @Test("Transport shutdown during optional discovery must not report startup success",
          .enabled(if: Self.node != nil, "requires Node"), arguments: ["resources/list", "prompts/list"])
    func shutdownDuringDiscovery(method: String) async throws {
        let (_, connection) = try fixture(method: method)
        let startup = MCPHeldTask<Result<Void, Error>> {
            do { try await connection.connect(); return .success(()) }
            catch { return .failure(error) }
        }
        do {
            try await waitForDiscovery(method, connection: connection)
            await connection.shutdown()
            switch try await startup.value() {
            case .success: Issue.record("Closed transport reported successful connection")
            case .failure: break
            }
            #expect(await connection.isRunning == false)
            #expect(await connection.tools.isEmpty)
        } catch {
            startup.cancel()
            await connection.shutdown()
            await startup.drain()
            throw error
        }
    }

    @Test("Server exit during optional discovery is a failed startup",
          .enabled(if: Self.node != nil, "requires Node"), arguments: ["resources/list", "prompts/list"])
    func exitDuringDiscovery(method: String) async throws {
        let (_, direct) = try fixture(method: method, exits: true)
        do {
            try await direct.connect()
            Issue.record("Exited server reported successful connection")
        } catch { }
        await direct.shutdown()

        let (config, connection) = try fixture(method: method, exits: true)
        let registry = MCPRegistry(configProvider: { [config] }, connectionFactory: { _ in connection })
        await registry.startEnabledServers()
        let rows = await registry.status()
        #expect(rows.count == 1)
        #expect(rows.allSatisfy { !$0.connected && $0.error != nil })
        #expect(await registry.availableTools().isEmpty)
        await registry.shutdownAll()
    }

    @Test("Optional discovery RPC errors still allow tools to connect",
          .enabled(if: Self.node != nil, "requires Node"), arguments: ["resources/list", "prompts/list"])
    func ordinaryErrorIsOptional(method: String) async throws {
        let (_, connection) = try fixture(method: method, errors: true)
        do {
            try await connection.connect()
            #expect(await connection.isRunning)
            #expect(await connection.tools.count == 1)
            await connection.shutdown()
        } catch {
            await connection.shutdown()
            throw error
        }
    }
}
