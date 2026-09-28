import Foundation

public final class SwiftPadSession: @unchecked Sendable {
    public let serverURL: URL
    public let isAuthenticated: Bool
    public var isActive: Bool { !bridge.isClosedOnAnyThread }
    public let edPublic: String?

    public let username: String?
    let bridge: JSBridge

    public let events: AsyncStream<SwiftPadEvent>
    private let eventsContinuation: AsyncStream<SwiftPadEvent>.Continuation

    private let padSessionRoutesLock = NSLock()
    private var padSessionRoutes: [String: WeakPadSessionBox] = [:]
    private let chatRoutesLock = NSLock()
    private var chatRoutes: [String: ChatRouteBox] = [:]
    private var dmContacts: [String: String] = [:]

    init(serverURL: URL, bridge: JSBridge, isAuthenticated: Bool, edPublic: String? = nil, username: String? = nil) {
        self.serverURL = serverURL
        self.isAuthenticated = isAuthenticated
        self.edPublic = edPublic
        self.username = username
        self.bridge = bridge
        let (stream, continuation) = AsyncStream<SwiftPadEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.events = stream
        self.eventsContinuation = continuation
        bridge.queue.sync {
            let weakContinuation = continuation
            bridge.eventHandler = { [weak self] name, payloadJSON in
                if name == "PAD_PATCH" {
                    self?.dispatchPadPatch(payloadJSON: payloadJSON)
                    return
                }
                if name == "PAD_SESSION_ERROR" {
                    self?.dispatchPadSessionError(payloadJSON: payloadJSON)
                    return
                }
                if name == "UNIVERSAL_EVENT" {
                    self?.dispatchUniversalEvent(payloadJSON: payloadJSON)
                    return
                }
                guard let event = SwiftPadEvent.decode(name: name, payloadJSON: payloadJSON) else {
                    Trace.debug(.bootstrap, "dropping unknown worker event '\(name)'")
                    return
                }
                if case .networkDisconnect = event {
                    self?.dispatchDisconnectToAllPadSessions()
                    self?.dispatchDisconnectToAllChatSessions()
                }
                weakContinuation.yield(event)
            }
        }
    }


    func registerPadSession(_ session: PadSession) {
        padSessionRoutesLock.lock()
        defer { padSessionRoutesLock.unlock() }
        padSessionRoutes[session.sessionId] = WeakPadSessionBox(session)
    }

    func unregisterPadSession(sessionId: String) {
        padSessionRoutesLock.lock()
        defer { padSessionRoutesLock.unlock() }
        padSessionRoutes.removeValue(forKey: sessionId)
    }

    private func dispatchPadPatch(payloadJSON: String) {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = obj["sessionId"] as? String,
              let raw = obj["raw"] as? String else {
            Trace.warn(.bootstrap, "PAD_PATCH payload malformed; dropping")
            return
        }
        let session = lookupPadSession(sessionId: sessionId)
        session?.dispatchPatch(raw: raw)
    }

    private func dispatchPadSessionError(payloadJSON: String) {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = obj["sessionId"] as? String,
              let code = obj["code"] as? String else {
            Trace.warn(.bootstrap, "PAD_SESSION_ERROR payload malformed; dropping")
            return
        }
        let session = lookupPadSession(sessionId: sessionId)
        session?.dispatchError(code: code)
    }

    private func dispatchDisconnectToAllPadSessions() {
        padSessionRoutesLock.lock()
        let boxes = Array(padSessionRoutes.values)
        padSessionRoutesLock.unlock()
        for box in boxes {
            box.ref?.dispatchDisconnect()
        }
    }


    func registerChatRoute(chatChannel: String, box: ChatRouteBox) {
        chatRoutesLock.lock()
        defer { chatRoutesLock.unlock() }
        chatRoutes[chatChannel] = box
    }

    func unregisterChatRoute(chatChannel: String) {
        chatRoutesLock.lock()
        defer { chatRoutesLock.unlock() }
        chatRoutes.removeValue(forKey: chatChannel)
    }

    private func lookupChatRoute(chatChannel: String) -> ChatRouteBox? {
        chatRoutesLock.lock()
        defer { chatRoutesLock.unlock() }
        return chatRoutes[chatChannel]
    }

    func registerDMContact(curvePublic: String, channel: String) {
        chatRoutesLock.lock()
        defer { chatRoutesLock.unlock() }
        dmContacts[curvePublic] = channel
    }

    func unregisterDMContact(curvePublic: String) {
        chatRoutesLock.lock()
        defer { chatRoutesLock.unlock() }
        dmContacts.removeValue(forKey: curvePublic)
    }

    private func lookupDMContact(curvePublic: String) -> String? {
        chatRoutesLock.lock()
        defer { chatRoutesLock.unlock() }
        return dmContacts[curvePublic]
    }

    private func dispatchDisconnectToAllChatSessions() {
        chatRoutesLock.lock()
        let boxes = Array(chatRoutes.values)
        chatRoutesLock.unlock()
        for box in boxes {
            box.session?.dispatchDisconnect()
        }
    }

    private func dispatchUniversalEvent(payloadJSON: String) {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              let inner = obj["data"] as? [String: Any],
              let ev = inner["ev"] as? String else {
            Trace.warn(.bootstrap, "UNIVERSAL_EVENT payload malformed; dropping")
            return
        }
        guard type == "messenger" else {
            Trace.debug(.bootstrap, "dropping UNIVERSAL_EVENT type '\(type)' ev '\(ev)'")
            return
        }
        switch ev {
        case "MESSAGE":
            guard let payload = inner["data"] as? [String: Any],
                  let channel = payload["channel"] as? String,
                  let message = ChatMessage.decode(payload) else {
                Trace.warn(.bootstrap, "messenger MESSAGE undecodable; dropping")
                return
            }
            lookupChatRoute(chatChannel: channel)?.dispatch(message)
        case "CLEAR_CHANNEL":
            guard let channel = inner["data"] as? String else {
                Trace.warn(.bootstrap, "messenger CLEAR_CHANNEL without channel id; dropping")
                return
            }
            lookupChatRoute(chatChannel: channel)?.dispatchClear()
        case "UNFRIEND":
            guard let payload = inner["data"] as? [String: Any],
                  let curvePublic = payload["curvePublic"] as? String else {
                Trace.warn(.bootstrap, "messenger UNFRIEND undecodable; dropping")
                return
            }
            if let channel = lookupDMContact(curvePublic: curvePublic) {
                lookupChatRoute(chatChannel: channel)?.dispatchUnfriended()
            }
        case "FRIEND":
            guard let payload = inner["data"] as? [String: Any],
                  let curvePublic = payload["curvePublic"] as? String else {
                Trace.warn(.bootstrap, "messenger FRIEND undecodable; dropping")
                return
            }
            eventsContinuation.yield(.contactDMReady(curvePublic: curvePublic))
        default:
            Trace.debug(.bootstrap, "dropping messenger event '\(ev)'")
        }
    }

    private func lookupPadSession(sessionId: String) -> PadSession? {
        padSessionRoutesLock.lock()
        defer { padSessionRoutesLock.unlock() }
        return padSessionRoutes[sessionId]?.ref
    }

    public func close() {
        bridge.syncOnQueue {
            padSessionRoutesLock.lock()
            let boxes = Array(padSessionRoutes.values)
            padSessionRoutesLock.unlock()
            for box in boxes { box.ref?.dispatchOwnerClosed() }
            chatRoutesLock.lock()
            let chatBoxes = Array(chatRoutes.values)
            chatRoutesLock.unlock()
            for box in chatBoxes { box.dispatchOwnerClosed() }
        }
        eventsContinuation.finish()
        bridge.close()
    }

    #if canImport(Darwin)
    public static func anonymous(serverURL: URL,
                                 webSocketFactory: WebSocketFactory = URLSessionWebSocketFactory(),
                                 httpClient: HTTPClient = URLSessionHTTPClient(),
                                 resourceProvider: JSResourceProvider = .bundle)
        async throws -> SwiftPadSession {
        do {
            return try await _anonymous(serverURL: serverURL,
                                        webSocketFactory: webSocketFactory,
                                        httpClient: httpClient,
                                        resourceProvider: resourceProvider)
        } catch {
            throw mapBridgeError(error)
        }
    }

    public static func signIn(serverURL: URL,
                              username: String,
                              password: String?,
                              totpCode: String? = nil,
                              scryptCache: SecureBlobStore? = nil,
                              scryptCachePolicy: SwiftPadCachePolicy = .biometricBound,
                              padCache: PadDocumentCache? = nil,
                              padChannels: [String] = [],
                              driveCache: DriveSnapshotCache? = nil,
                              webSocketFactory: WebSocketFactory = URLSessionWebSocketFactory(),
                              httpClient: HTTPClient = URLSessionHTTPClient(),
                              resourceProvider: JSResourceProvider = .bundle)
        async throws -> SwiftPadSession {
        do {
            return try await _signIn(serverURL: serverURL,
                                     username: username,
                                     password: password,
                                     totpCode: totpCode,
                                     scryptCache: scryptCache,
                                     scryptCachePolicy: scryptCachePolicy,
                                     padCache: padCache,
                                     padChannels: padChannels,
                                     driveCache: driveCache,
                                     webSocketFactory: webSocketFactory,
                                     httpClient: httpClient,
                                     resourceProvider: resourceProvider)
        } catch {
            throw mapBridgeError(error)
        }
    }
    public static func signUp(serverURL: URL,
                              username: String,
                              password: String,
                              webSocketFactory: WebSocketFactory = URLSessionWebSocketFactory(),
                              httpClient: HTTPClient = URLSessionHTTPClient(),
                              resourceProvider: JSResourceProvider = .bundle)
        async throws -> SwiftPadSession {
        do {
            return try await _signUp(serverURL: serverURL,
                                     username: username,
                                     password: password,
                                     webSocketFactory: webSocketFactory,
                                     httpClient: httpClient,
                                     resourceProvider: resourceProvider)
        } catch {
            throw mapBridgeError(error)
        }
    }
    #else
    public static func anonymous(serverURL: URL,
                                 webSocketFactory: WebSocketFactory,
                                 httpClient: HTTPClient,
                                 resourceProvider: JSResourceProvider)
        async throws -> SwiftPadSession {
        do {
            return try await _anonymous(serverURL: serverURL,
                                        webSocketFactory: webSocketFactory,
                                        httpClient: httpClient,
                                        resourceProvider: resourceProvider)
        } catch {
            throw mapBridgeError(error)
        }
    }

    public static func signIn(serverURL: URL,
                              username: String,
                              password: String?,
                              totpCode: String? = nil,
                              scryptCache: SecureBlobStore? = nil,
                              scryptCachePolicy: SwiftPadCachePolicy = .biometricBound,
                              padCache: PadDocumentCache? = nil,
                              padChannels: [String] = [],
                              driveCache: DriveSnapshotCache? = nil,
                              webSocketFactory: WebSocketFactory,
                              httpClient: HTTPClient,
                              resourceProvider: JSResourceProvider)
        async throws -> SwiftPadSession {
        do {
            return try await _signIn(serverURL: serverURL,
                                     username: username,
                                     password: password,
                                     totpCode: totpCode,
                                     scryptCache: scryptCache,
                                     scryptCachePolicy: scryptCachePolicy,
                                     padCache: padCache,
                                     padChannels: padChannels,
                                     driveCache: driveCache,
                                     webSocketFactory: webSocketFactory,
                                     httpClient: httpClient,
                                     resourceProvider: resourceProvider)
        } catch {
            throw mapBridgeError(error)
        }
    }

    public static func signUp(serverURL: URL,
                              username: String,
                              password: String,
                              webSocketFactory: WebSocketFactory,
                              httpClient: HTTPClient,
                              resourceProvider: JSResourceProvider)
        async throws -> SwiftPadSession {
        do {
            return try await _signUp(serverURL: serverURL,
                                     username: username,
                                     password: password,
                                     webSocketFactory: webSocketFactory,
                                     httpClient: httpClient,
                                     resourceProvider: resourceProvider)
        } catch {
            throw mapBridgeError(error)
        }
    }
    #endif

    public static func evictAllCaches(
        username: String,
        loginSalt: String,
        serverURL: URL,
        scryptCache: SecureBlobStore? = nil,
        padCache: PadDocumentCache? = nil,
        padChannels: [String] = [],
        driveCache: DriveSnapshotCache? = nil,
        teamIds: [String] = []
    ) async throws {
        var driveError: Error?
        var bearerError: Error?
        var scryptError: Error?
        var wipeError: Error?
        var failedPadChannels: [String] = []

        if let driveCache = driveCache {
            do {
                try await driveCache.evict(username: username, serverURL: serverURL)
            } catch {
                driveError = error
            }
            for teamId in teamIds {
                do {
                    try await driveCache.evict(username: username, serverURL: serverURL, teamId: teamId)
                } catch {
                    if driveError == nil { driveError = error }
                }
            }
        }
        if let padCache = padCache {
            for channel in padChannels {
                do {
                    try await padCache.evict(channel: channel)
                } catch {
                    failedPadChannels.append(channel)
                }
            }
        }
        if let scryptCache = scryptCache {
            let bearerWrapper = BearerCache(backend: scryptCache, policy: .biometricBound)
            do {
                try await bearerWrapper.evict(username: username, loginSalt: loginSalt, serverURL: serverURL)
            } catch {
                bearerError = error
            }
            let wrapper = ScryptCache(backend: scryptCache, policy: .biometricBound)
            do {
                try await wrapper.evict(username: username, loginSalt: loginSalt, serverURL: serverURL)
            } catch {
                scryptError = error
            }
        }

        var wiped: Set<ObjectIdentifier> = []
        var backends: [SecureBlobStore] = []
        if let scryptCache = scryptCache { backends.append(scryptCache) }
        if let padCache = padCache { backends.append(padCache.backend) }
        if let driveCache = driveCache { backends.append(driveCache.backend) }
        for backend in backends {
            let id = ObjectIdentifier(backend as AnyObject)
            if wiped.contains(id) { continue }
            wiped.insert(id)
            do {
                try await backend.evictAll(prefix: "swiftpad-")
            } catch {
                wipeError = wipeError ?? error
            }
        }

        if let driveError = driveError {
            throw driveError
        }
        if let scryptError = scryptError {
            throw scryptError
        }
        if let bearerError = bearerError {
            throw bearerError
        }
        if !failedPadChannels.isEmpty {
            throw SwiftPadError.partialEviction(failedChannels: failedPadChannels)
        }
        if let wipeError = wipeError {
            throw wipeError
        }
    }

    private static func _anonymous(serverURL: URL,
                                   webSocketFactory: WebSocketFactory,
                                   httpClient: HTTPClient,
                                   resourceProvider: JSResourceProvider)
        async throws -> SwiftPadSession {
        try requireTransportSafeServerURL(serverURL)
        let bridge = try await makeBridge(for: serverURL,
                                          webSocketFactory: webSocketFactory,
                                          httpClient: httpClient,
                                          resourceProvider: resourceProvider)
        let apiConfig = try await CryptPadAPI.fetchConfig(serverURL: serverURL, client: httpClient)
        try requireHTTPUnsafeOrigin(apiConfig)
        try requireAdmissibleWebsocketPath(serverURL: serverURL, apiConfig: apiConfig)
        let broadcast = try await CryptPadAPI.fetchBroadcast(serverURL: serverURL, client: httpClient)
        bridge.setAllowedOrigins(deriveAllowedOrigins(serverURL: serverURL, apiConfig: apiConfig))
        _ = try await bridge.callAsync("__swiftpad.anonymous", args: [apiConfig, broadcast],
                                       timeoutSeconds: 130)
        return SwiftPadSession(serverURL: serverURL, bridge: bridge, isAuthenticated: false)
    }

    private static func _signIn(serverURL: URL,
                                username rawUsername: String,
                                password: String?,
                                totpCode: String?,
                                scryptCache scryptCacheBackend: SecureBlobStore?,
                                scryptCachePolicy: SwiftPadCachePolicy,
                                padCache: PadDocumentCache?,
                                padChannels: [String],
                                driveCache: DriveSnapshotCache?,
                                webSocketFactory: WebSocketFactory,
                                httpClient: HTTPClient,
                                resourceProvider: JSResourceProvider)
        async throws -> SwiftPadSession {
        guard !rawUsername.isEmpty else {
            throw SwiftPadError.protocolError("username must be non-empty")
        }
        if let password, password.isEmpty {
            throw SwiftPadError.protocolError("password must be non-empty")
        }
        if password == nil && scryptCacheBackend == nil {
            throw SwiftPadError.authFailed(reason: .passwordRequired)
        }
        if let totpCode = totpCode {
            guard totpCode.count == 6,
                  totpCode.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw SwiftPadError.authFailed(reason: .totpInvalid)
            }
        }
        let username = rawUsername.lowercased()

        try requireTransportSafeServerURL(serverURL)
        let bridge = try await makeBridge(for: serverURL,
                                          webSocketFactory: webSocketFactory,
                                          httpClient: httpClient,
                                          resourceProvider: resourceProvider)
        let apiConfig = try await CryptPadAPI.fetchConfig(serverURL: serverURL, client: httpClient)
        try requireHTTPUnsafeOrigin(apiConfig)
        try requireAdmissibleWebsocketPath(serverURL: serverURL, apiConfig: apiConfig)
        let broadcast = try await CryptPadAPI.fetchBroadcast(serverURL: serverURL, client: httpClient)
        bridge.setAllowedOrigins(deriveAllowedOrigins(serverURL: serverURL, apiConfig: apiConfig))

        let scryptCache: ScryptCache?
        if let backend = scryptCacheBackend {
            scryptCache = ScryptCache(backend: backend, policy: scryptCachePolicy)
        } else {
            scryptCache = nil
        }
        let loginSalt = try await readLoginSalt(bridge: bridge)

        if let scryptCache = scryptCache {
            let salt = loginSalt
            let bearerCache = BearerCache(backend: scryptCache.backend, policy: scryptCachePolicy)
            let cachedBytes: Data?
            do {
                cachedBytes = try await scryptCache.fetch(username: username, loginSalt: salt, serverURL: serverURL)
            } catch {
                if password == nil { throw error }
                Trace.warn(.session, "scrypt cache fetch failed: \(error); proceeding with fresh signin")
                cachedBytes = nil
            }
            if let cachedBytes = cachedBytes {
                var bearer: String? = nil
                do {
                    bearer = try await bearerCache.fetch(username: username, loginSalt: salt, serverURL: serverURL)
                } catch {
                    Trace.warn(.session, "bearer cache fetch failed: \(error); signing in without a bearer")
                }
                do {
                    let resultJSON = try await callSignInWithCachedKeys(
                        bridge: bridge,
                        scryptBytes: cachedBytes,
                        apiConfig: apiConfig,
                        broadcast: broadcast,
                        totpCode: totpCode,
                        bearer: bearer
                    )
                    if isTotpRequiredSentinel(resultJSON) {
                        if bearer != nil && isBearerRejectedSentinel(resultJSON) {
                            do {
                                try await bearerCache.evict(username: username, loginSalt: salt, serverURL: serverURL)
                                Trace.debug(.session, "bearer cache evicted after a 401 on the cached bearer")
                            } catch {
                                Trace.warn(.session, "bearer cache evict failed after a 401: \(error)")
                            }
                        }
                        throw SwiftPadError.authFailed(reason: .totpRequired)
                    }
                    Trace.debug(.session, "signIn (cached) succeeded — user=\(Trace.hashShort(username)) payloadBytes=\(resultJSON.count)")
                    if let minted = extractMintedBearer(from: resultJSON) {
                        do {
                            try await bearerCache.store(username: username, loginSalt: salt, serverURL: serverURL, bearer: minted)
                        } catch {
                            Trace.warn(.session, "bearer cache store failed: \(error); the next sign-in asks for a code")
                        }
                    }
                    let edPublic = extractEdPublic(from: resultJSON)
                    return SwiftPadSession(serverURL: serverURL, bridge: bridge, isAuthenticated: true, edPublic: edPublic, username: username)
                } catch JSBridgeError.bridgeClosed {
                    throw JSBridgeError.bridgeClosed
                } catch let error as SwiftPadError where isTotpOutcome(error) {
                    throw error
                } catch let error as SwiftPadError where error == .protocolError(Self.ssoRefusalMessage) {
                    do {
                        try await bearerCache.evict(username: username, loginSalt: salt, serverURL: serverURL)
                    } catch let evictErr {
                        Trace.warn(.session, "bearer cache evict failed after SSO refusal: \(evictErr)")
                    }
                    do {
                        try await scryptCache.evict(username: username, loginSalt: salt, serverURL: serverURL)
                        Trace.debug(.session, "scrypt cache evicted after SSO refusal (scrypt + bearer only, no cascade)")
                    } catch let evictErr {
                        Trace.warn(.session, "scrypt cache evict failed after SSO refusal: \(evictErr)")
                    }
                    throw error
                } catch {
                    if let driveCache = driveCache {
                        do {
                            try await driveCache.evict(username: username, serverURL: serverURL)
                            try await driveCache.backend.evictAll(prefix: "swiftpad-drive-")
                        } catch let dErr {
                            Trace.warn(.session, "drive cache cascade-flush failed: \(dErr); fresh signin still proceeding")
                        }
                    }
                    if let padCache = padCache {
                        for channel in padChannels {
                            do {
                                try await padCache.evict(channel: channel)
                            } catch {
                            }
                        }
                    }
                    do {
                        try await bearerCache.evict(username: username, loginSalt: salt, serverURL: serverURL)
                    } catch let evictErr {
                        Trace.warn(.session, "bearer cache evict failed in the cascade: \(evictErr)")
                    }
                    do {
                        try await scryptCache.evict(username: username, loginSalt: salt, serverURL: serverURL)
                        Trace.debug(.session, "scrypt cache evicted after \(type(of: error)); retrying fresh signin")
                    } catch let evictErr {
                        Trace.warn(.session, "scrypt cache evict failed: \(evictErr); retrying fresh signin (cache may still hold stale entry)")
                    }
                }
            }
        }

        guard let password else {
            throw SwiftPadError.authFailed(reason: .passwordRequired)
        }
        var derivedBytes = try Scrypt.deriveCryptPadLogin(
            password: password, salt: username + loginSalt)
        let scryptBytes = Data(derivedBytes)
        derivedBytes.withUnsafeMutableBytes { Scrypt.zeroBytes($0) }

        let resultJSON = try await callSignInWithCachedKeys(
            bridge: bridge,
            scryptBytes: scryptBytes,
            apiConfig: apiConfig,
            broadcast: broadcast,
            totpCode: totpCode,
            bearer: nil
        )

        if isTotpRequiredSentinel(resultJSON) {
            if let scryptCache = scryptCache {
                do {
                    try await scryptCache.store(username: username, loginSalt: loginSalt, serverURL: serverURL, scryptBytes: scryptBytes)
                } catch {
                    Trace.warn(.session, "scrypt cache store failed on totpRequired: \(error); code-bearing retry will re-derive")
                }
            }
            throw SwiftPadError.authFailed(reason: .totpRequired)
        }

        Trace.debug(.session, "signIn (native scrypt) succeeded — user=\(Trace.hashShort(username)) payloadBytes=\(resultJSON.count)")

        if let scryptCache = scryptCache {
            do {
                try await scryptCache.store(username: username, loginSalt: loginSalt, serverURL: serverURL, scryptBytes: scryptBytes)
            } catch {
                Trace.warn(.session, "scrypt cache store failed: \(error); session is fine but next signin will re-derive")
            }
        }
        if let scryptCache = scryptCache, let minted = extractMintedBearer(from: resultJSON) {
            let bearerCache = BearerCache(backend: scryptCache.backend, policy: scryptCachePolicy)
            do {
                try await bearerCache.store(username: username, loginSalt: loginSalt, serverURL: serverURL, bearer: minted)
            } catch {
                Trace.warn(.session, "bearer cache store failed: \(error); the next sign-in asks for a code")
            }
        }

        let edPublic = extractEdPublic(from: resultJSON)
        return SwiftPadSession(serverURL: serverURL, bridge: bridge, isAuthenticated: true, edPublic: edPublic, username: username)
    }

    private static func _signUp(serverURL: URL,
                                username rawUsername: String,
                                password: String,
                                webSocketFactory: WebSocketFactory,
                                httpClient: HTTPClient,
                                resourceProvider: JSResourceProvider)
        async throws -> SwiftPadSession {
        try requireTransportSafeServerURL(serverURL)
        let trimmed = jsTrim(rawUsername)
        guard !trimmed.isEmpty else {
            throw SwiftPadError.protocolError("username must be non-empty")
        }
        guard !password.isEmpty else {
            throw SwiftPadError.protocolError("password must be non-empty")
        }
        if trimmed.utf16.count > maximumUsernameLength {
            throw SwiftPadError.signUpFailed(reason: .usernameTooLong(maximum: maximumUsernameLength))
        }
        let bridge = try await makeBridge(for: serverURL,
                                          webSocketFactory: webSocketFactory,
                                          httpClient: httpClient,
                                          resourceProvider: resourceProvider)
        let minimumPasswordLength = try await readMinimumPasswordLength(bridge: bridge)
        if password.utf16.count < minimumPasswordLength {
            throw SwiftPadError.signUpFailed(reason: .passwordTooShort(minimum: minimumPasswordLength))
        }
        let username = trimmed.lowercased()

        let apiConfig = try await CryptPadAPI.fetchConfig(serverURL: serverURL, client: httpClient)
        try requireHTTPUnsafeOrigin(apiConfig)
        try requireAdmissibleWebsocketPath(serverURL: serverURL, apiConfig: apiConfig)
        let broadcast = try await CryptPadAPI.fetchBroadcast(serverURL: serverURL, client: httpClient)
        bridge.setAllowedOrigins(deriveAllowedOrigins(serverURL: serverURL, apiConfig: apiConfig))
        if (apiConfig["restrictRegistration"] as? Bool) == true {
            throw SwiftPadError.signUpFailed(reason: .registrationClosed)
        }

        let loginSalt = try await readLoginSalt(bridge: bridge)
        var derivedBytes = try Scrypt.deriveCryptPadLogin(
            password: password, salt: username + loginSalt)
        let scryptBytes = Data(derivedBytes)
        derivedBytes.withUnsafeMutableBytes { Scrypt.zeroBytes($0) }

        let resultJSON: String
        do {
            resultJSON = try await bridge.callAsync(
                "__swiftpad.signUp",
                args: [scryptBytes.base64EncodedString(), apiConfig, broadcast, ["username": username]],
                timeoutSeconds: 180
            )
        } catch {
            throw mapAuthError(error)
        }
        if isTotpRequiredSentinel(resultJSON) {
            throw SwiftPadError.protocolError("signUp: unexpected TOTP gate on a freshly written block")
        }
        Trace.debug(.session, "signUp succeeded — user=\(Trace.hashShort(username)) payloadBytes=\(resultJSON.count)")
        let edPublic = extractEdPublic(from: resultJSON)
        return SwiftPadSession(serverURL: serverURL, bridge: bridge, isAuthenticated: true, edPublic: edPublic, username: username)
    }

    static let maximumUsernameLength = 64

    private static func readMinimumPasswordLength(bridge: JSBridge) async throws -> Int {
        let resultJSON = try await bridge.callAsync("__swiftpad.getSignUpRules", args: [])
        guard let data = resultJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let minimum = obj["minimumPasswordLength"] as? Int, minimum >= 1 else {
            throw SwiftPadError.protocolError("getSignUpRules returned malformed payload")
        }
        return minimum
    }

    static let jsWhiteSpaceScalars: Set<Unicode.Scalar> = [
        "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}",
        "\u{0020}", "\u{00A0}", "\u{1680}",
        "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}",
        "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}",
        "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}",
    ]

    static func jsTrim(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, jsWhiteSpaceScalars.contains(scalars[start]) { start += 1 }
        while end > start, jsWhiteSpaceScalars.contains(scalars[end - 1]) { end -= 1 }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[start..<end])
        return String(out)
    }

    static func requireTransportSafeServerURL(_ serverURL: URL) throws {
        guard let scheme = serverURL.scheme?.lowercased(), scheme == "http" else { return }
        let host = (serverURL.host ?? "").lowercased()
        guard !host.isEmpty else { return }
        if !isLoopbackHost(host) {
            throw SwiftPadError.protocolError(
                "serverURL must use https:// for non-loopback hosts (got http:// to \(host)) — plaintext boot fetches would expose the server name and a downgrade lever")
        }
    }

    private static func callSignInWithCachedKeys(bridge: JSBridge,
                                                 scryptBytes: Data,
                                                 apiConfig: [String: Any],
                                                 broadcast: [String: Any],
                                                 totpCode: String?,
                                                 bearer: String?)
        async throws -> String {
        let scryptBytesB64 = scryptBytes.base64EncodedString()
        var options: [String: Any] = [:]
        if let totpCode = totpCode {
            options["totpCode"] = totpCode
        }
        if let bearer = bearer {
            options["bearer"] = bearer
        }
        do {
            return try await bridge.callAsync(
                "__swiftpad.signInWithCachedKeys",
                args: [scryptBytesB64, apiConfig, broadcast, options],
                timeoutSeconds: 130
            )
        } catch {
            throw mapAuthError(error)
        }
    }

    private static let ssoRefusalMessage =
        "signIn: account requires SSO login — unsupported by SwiftPad (use the web client)"

    private static func isTotpOutcome(_ error: SwiftPadError) -> Bool {
        guard case .authFailed(let reason) = error else { return false }
        switch reason {
        case .totpRequired, .totpInvalid, .totpValidateFailed:
            return true
        case .blockNotFound, .blockDecryptFailed, .blockFetchFailed, .passwordRequired:
            return false
        }
    }

    private static func isTotpRequiredSentinel(_ resultJSON: String) -> Bool {
        guard let data = resultJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flag = obj["totpRequired"] as? Bool else { return false }
        return flag
    }

    private static func isBearerRejectedSentinel(_ resultJSON: String) -> Bool {
        guard let data = resultJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flag = obj["bearerRejected"] as? Bool else { return false }
        return flag
    }

    private static func extractMintedBearer(from resultJSON: String) -> String? {
        guard let data = resultJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bearer = obj["bearer"] as? String else { return nil }
        guard BearerCache.isWellFormed(bearer) else {
            Trace.warn(.session, "minted bearer malformed (\(bearer.utf8.count) bytes) — not stored")
            return nil
        }
        return bearer
    }

    static func readLoginSalt(bridge: JSBridge) async throws -> String {
        let resultJSON = try await bridge.callAsync("__swiftpad.getLoginSalt", args: [])
        guard let data = resultJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let salt = obj["loginSalt"] as? String else {
            throw SwiftPadError.protocolError("getLoginSalt returned malformed payload")
        }
        return salt
    }

    private static func mapAuthError(_ error: Error) -> Error {
        guard case JSBridgeError.jsRejection(let message) = error,
              let data = message.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = parsed["code"] as? String else {
            return error
        }
        switch code {
        case "BLOCK_NOT_FOUND":
            return SwiftPadError.authFailed(reason: .blockNotFound)
        case "BLOCK_DECRYPT_FAILED":
            return SwiftPadError.authFailed(reason: .blockDecryptFailed)
        case "BLOCK_FETCH_FAILED":
            let status = (parsed["httpStatus"] as? Int) ?? -1
            return SwiftPadError.authFailed(reason: .blockFetchFailed(status: status))
        case "SSO_UNSUPPORTED":
            return SwiftPadError.protocolError(Self.ssoRefusalMessage)
        case "TOTP_INVALID":
            return SwiftPadError.authFailed(reason: .totpInvalid)
        case "TOTP_VALIDATE_FAILED":
            let detail = (parsed["detail"] as? String) ?? "(detail missing — envelope drift)"
            return SwiftPadError.authFailed(reason: .totpValidateFailed(detail: detail))
        case "ALREADY_REGISTERED":
            return SwiftPadError.signUpFailed(reason: .alreadyRegistered)
        case "REGISTRATION_CLOSED":
            return SwiftPadError.signUpFailed(reason: .registrationClosed)
        case "DELETED_USER":
            let reason = (parsed["reason"] as? String) ?? "(reason missing — envelope drift)"
            return SwiftPadError.signUpFailed(reason: .deletedAccount(reason: reason))
        case "BLOCK_WRITE_FAILED", "DRIVE_SEED_FAILED", "LEGACY_CHECK_FAILED":
            let detail = (parsed["detail"] as? String) ?? "(detail missing — envelope drift)"
            return SwiftPadError.signUpFailed(reason: .blockWriteFailed(detail: code + ": " + detail))
        default:
            return error
        }
    }

    private static func extractEdPublic(from resultJSON: String) -> String? {
        guard let data = resultJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edPublic = obj["edPublic"] as? String else { return nil }
        return edPublic
    }

    public func rpc(_ command: String,
                    payload: [String: Any] = [:]) async throws -> Data {
        try await callAsData("__swiftpad.rpc", args: [command, payload])
    }

    public func getDrive() async throws -> [DriveEntry] {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        struct Envelope: Decodable { let entries: [DriveEntry] }
        let env: Envelope = try await callAndDecode("__swiftpad.getDrive", args: [])
        return env.entries
    }

    public func getDriveTree() async throws -> DriveTree {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        return try await callAndDecode("__swiftpad.getDriveTree", args: [])
    }

    public func captureDriveSnapshot() async throws -> String {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        struct Envelope: Decodable { let driveUserDoc: String }
        let env: Envelope = try await callAndDecode("__swiftpad.serializeDriveForCache", args: [])
        return env.driveUserDoc
    }

    public func captureTeamDriveSnapshot(teamId: String) async throws -> String {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.requireTeamId(teamId, verb: "captureTeamDriveSnapshot")
        struct Envelope: Decodable { let driveUserDoc: String }
        let env: Envelope = try await callAndDecode("__swiftpad.serializeDriveForCache", args: [teamId])
        return env.driveUserDoc
    }

    public func movePad(channel: String, toPath: [String]) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await callAsData("__swiftpad.movePad", args: [channel, toPath])
    }

    public func purgeTrash() async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await callAsData("__swiftpad.purgeTrash", args: [])
    }

    public func getPadAttribute(channel: String, attr: String) async throws -> String? {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        struct Envelope: Decodable { let value: String? }
        let env: Envelope = try await callAndDecode("__swiftpad.getPadAttribute", args: [channel, attr])
        return env.value
    }

    public func setPadAttribute(channel: String, attr: String, value: String?) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        let valueArg: Any = value ?? NSNull()
        _ = try await callAsData("__swiftpad.setPadAttribute", args: [channel, attr, valueArg])
    }

    private static func validateAttributePath(_ path: [String], _ caller: String) throws {
        if path.first == "settings" {
            throw SwiftPadError.protocolError(
                "\(caller): paths are relative to proxy.settings — drop the leading \"settings\" component (the worker prepends it; keeping it writes a junk settings.settings subtree)")
        }
        let unsafe = ["__proto__", "constructor", "prototype"]
        if let bad = path.first(where: { unsafe.contains($0) }) {
            throw SwiftPadError.protocolError(
                "\(caller): path component \"\(bad)\" is not addressable (prototype-chain key; would write outside the settings tree)")
        }
    }

    public func getAttribute(path: [String]) async throws -> String? {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.validateAttributePath(path, "getAttribute")
        struct Envelope: Decodable { let value: String? }
        let env: Envelope = try await callAndDecode("__swiftpad.getAttribute", args: [path])
        return env.value
    }

    public func setAttribute(path: [String], value: String?) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.validateAttributePath(path, "setAttribute")
        let valueArg: Any = value ?? NSNull()
        _ = try await callAsData("__swiftpad.setAttribute", args: [path, valueArg])
    }


    public func getPadAttributeArray(channel: String, attr: String) async throws -> [String]? {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        struct Envelope: Decodable { let value: [String]? }
        let data = try await callAsData("__swiftpad.getPadAttributeRaw", args: [channel, attr])
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            Trace.warn(.bridge, "getPadAttributeArray: wrong shape for attr='\(attr)' on channel='\(channel)'")
            return nil
        }
        return env.value
    }

    public func setPadAttributeArray(channel: String, attr: String, value: [String]) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await callAsData("__swiftpad.setPadAttribute", args: [channel, attr, value])
    }

    public func getAttributeArray(path: [String]) async throws -> [String]? {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.validateAttributePath(path, "getAttributeArray")
        struct Envelope: Decodable { let value: [String]? }
        let data = try await callAsData("__swiftpad.getAttributeRaw", args: [path])
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            Trace.warn(.bridge, "getAttributeArray: wrong shape for path=\(path)")
            return nil
        }
        return env.value
    }

    public func setAttributeArray(path: [String], value: [String]) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.validateAttributePath(path, "setAttributeArray")
        _ = try await callAsData("__swiftpad.setAttribute", args: [path, value])
    }


    public func getAttributeBool(path: [String]) async throws -> Bool? {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.validateAttributePath(path, "getAttributeBool")
        struct Envelope: Decodable { let value: Bool? }
        let data = try await callAsData("__swiftpad.getAttributeRaw", args: [path])
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            Trace.warn(.bridge, "getAttributeBool: wrong shape for path=\(path)")
            return nil
        }
        return env.value
    }

    public func setAttributeBool(path: [String], value: Bool) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.validateAttributePath(path, "setAttributeBool")
        _ = try await callAsData("__swiftpad.setAttribute", args: [path, value])
    }

    public func getAttributeInt(path: [String]) async throws -> Int? {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.validateAttributePath(path, "getAttributeInt")
        struct Envelope: Decodable { let value: Int? }
        let data = try await callAsData("__swiftpad.getAttributeRaw", args: [path])
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            Trace.warn(.bridge, "getAttributeInt: wrong shape for path=\(path)")
            return nil
        }
        return env.value
    }

    public func setAttributeInt(path: [String], value: Int) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.validateAttributePath(path, "setAttributeInt")
        guard value >= -Self.jsMaxSafeInteger && value <= Self.jsMaxSafeInteger else {
            throw SwiftPadError.protocolError(
                "setAttributeInt: \(value) exceeds JS safe-integer range (±\(Self.jsMaxSafeInteger)) — the value would be stored lossily as a double")
        }
        _ = try await callAsData("__swiftpad.setAttribute", args: [path, value])
    }

    private static let jsMaxSafeInteger = 9_007_199_254_740_991

    public func getAttributeRawJSON(path: [String]) async throws -> String? {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.validateAttributePath(path, "getAttributeRawJSON")
        let data = try await callAsData("__swiftpad.getAttributeRaw", args: [path])
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return Self.reserialize(envelope["value"])
    }


    public func getPadTags(channel: String) async throws -> [String] {
        return try await getPadAttributeArray(channel: channel, attr: "tags") ?? []
    }

    public func setPadTags(channel: String, tags: [String]) async throws {
        try await setPadAttributeArray(channel: channel, attr: "tags", value: tags)
    }

    public func setDisplayName(_ name: String) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await callAsData("__swiftpad.setDisplayName", args: [name])
    }

    public func getPinnedUsage() async throws -> PinnedUsage {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        return try await callAndDecode("__swiftpad.getPinnedUsage", args: [])
    }

    public func getPinLimit() async throws -> PinLimit {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        return try await callAndDecode("__swiftpad.getPinLimit", args: [])
    }


    private static func boolish(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue != 0 }
        return false
    }

    private static func requireTeamId(_ teamId: String, verb: String) throws {
        guard !teamId.isEmpty else {
            throw SwiftPadError.protocolError("\(verb): teamId must be non-empty")
        }
    }

    private func evictTeamSnapshot(teamId: String, driveCache: DriveSnapshotCache?) async {
        guard let driveCache, let username else { return }
        try? await driveCache.evict(username: username, serverURL: serverURL, teamId: teamId)
    }

    public func listTeams() async throws -> [String: TeamSummary] {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        let data = try await callAsData("__swiftpad.listTeams", args: [])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let teams = obj["teams"] as? [String: Any] else {
            throw SwiftPadError.protocolError("listTeams: reply missing teams object")
        }
        var out: [String: TeamSummary] = [:]
        for (id, raw) in teams {
            guard let entry = raw as? [String: Any] else { continue }
            out[id] = Self.teamSummary(id: id, entry: entry)
        }
        return out
    }

    private static func teamSummary(id: String, entry: [String: Any]) -> TeamSummary {
        let metadata = entry["metadata"] as? [String: Any]
        let keys = entry["keys"] as? [String: Any]
        let drive = keys?["drive"] as? [String: Any]
        return TeamSummary(
            id: id,
            name: (metadata?["name"] as? String) ?? "",
            owner: Self.boolish(entry["owner"]),
            offline: Self.boolish(entry["offline"]),
            error: Self.boolish(entry["error"]),
            driveEdPublic: drive?["edPublic"] as? String
        )
    }

    public func getTeamRoster(teamId: String) async throws -> [String: TeamMember] {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.requireTeamId(teamId, verb: "getTeamRoster")
        let data = try await callAsData("__swiftpad.getTeamRoster", args: [teamId])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let members = obj["members"] as? [String: Any] else {
            throw SwiftPadError.protocolError("getTeamRoster: reply missing members object")
        }
        var out: [String: TeamMember] = [:]
        for (curvePublic, raw) in members {
            guard let m = raw as? [String: Any] else { continue }
            out[curvePublic] = TeamMember(
                curvePublic: curvePublic,
                edPublic: m["edPublic"] as? String,
                displayName: m["displayName"] as? String,
                role: TeamRole(wireString: m["role"] as? String),
                profile: m["profile"] as? String,
                avatar: m["avatar"] as? String,
                badge: m["badge"] as? String,
                uid: m["uid"] as? String,
                notifications: m["notifications"] as? String,
                pendingOwner: m["pendingOwner"] as? Bool,
                online: m["online"] as? Bool,
                pending: m["pending"] as? Bool,
                remaining: m["remaining"] as? Int,
                totalUses: m["totalUses"] as? Int,
                inviteChannel: m["inviteChannel"] as? String,
                previewChannel: m["previewChannel"] as? String,
                inviteHash: m["hash"] as? String
            )
        }
        return out
    }

    public func getTeamMetadata(teamId: String) async throws -> TeamMetadata {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.requireTeamId(teamId, verb: "getTeamMetadata")
        let data = try await callAsData("__swiftpad.getTeamMetadata", args: [teamId])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwiftPadError.protocolError("getTeamMetadata: reply is not a JSON object")
        }
        return TeamMetadata(
            name: (obj["name"] as? String) ?? "",
            topic: obj["topic"] as? String,
            avatar: obj["avatar"] as? String,
            offline: Self.boolish(obj["offline"])
        )
    }

    public func getTeamDrive(teamId: String) async throws -> [DriveEntry] {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.requireTeamId(teamId, verb: "getTeamDrive")
        struct Envelope: Decodable { let entries: [DriveEntry] }
        let env: Envelope = try await callAndDecode("__swiftpad.getTeamDrive", args: [teamId])
        return env.entries
    }

    public func getTeamPinnedUsage(teamId: String) async throws -> PinnedUsage {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.requireTeamId(teamId, verb: "getTeamPinnedUsage")
        return try await callAndDecode("__swiftpad.getTeamPinnedUsage", args: [teamId])
    }

    public func getTeamPinLimit(teamId: String) async throws -> PinLimit {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.requireTeamId(teamId, verb: "getTeamPinLimit")
        return try await callAndDecode("__swiftpad.getTeamPinLimit", args: [teamId])
    }

    public func createTeam(name: String) async throws -> TeamSummary {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SwiftPadError.protocolError("createTeam: name must be non-blank")
        }
        let data = try await callAsData("__swiftpad.createTeam", args: [name])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let entry = obj["entry"] as? [String: Any] else {
            throw SwiftPadError.protocolError("createTeam: reply missing id/entry")
        }
        return Self.teamSummary(id: id, entry: entry)
    }

    public func leaveTeam(teamId: String, driveCache: DriveSnapshotCache? = nil) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.requireTeamId(teamId, verb: "leaveTeam")
        do {
            _ = try await callAsData("__swiftpad.leaveTeam", args: [teamId])
        } catch {
            await evictTeamSnapshot(teamId: teamId, driveCache: driveCache)
            throw error
        }
        await evictTeamSnapshot(teamId: teamId, driveCache: driveCache)
    }

    public func deleteTeam(teamId: String, driveCache: DriveSnapshotCache? = nil) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.requireTeamId(teamId, verb: "deleteTeam")
        do {
            _ = try await callAsData("__swiftpad.deleteTeam", args: [teamId])
        } catch {
            await evictTeamSnapshot(teamId: teamId, driveCache: driveCache)
            throw error
        }
        await evictTeamSnapshot(teamId: teamId, driveCache: driveCache)
    }

    public func setTeamMetadata(teamId: String, name: String? = nil, topic: String? = nil, avatar: String? = nil) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.requireTeamId(teamId, verb: "setTeamMetadata")
        guard name != nil || topic != nil || avatar != nil else {
            throw SwiftPadError.protocolError("setTeamMetadata: at least one of name/topic/avatar must be provided")
        }
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SwiftPadError.protocolError("setTeamMetadata: name must be non-blank when provided")
        }
        var updates: [String: Any] = [:]
        if let name { updates["name"] = name }
        if let topic { updates["topic"] = topic }
        if let avatar { updates["avatar"] = avatar }
        _ = try await callAsData("__swiftpad.setTeamMetadata", args: [teamId, updates])
    }

    public func inviteToTeam(teamId: String, contact: Contact) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.requireTeamId(teamId, verb: "inviteToTeam")
        guard !contact.pending else {
            throw SwiftPadError.protocolError("inviteToTeam: pending contacts have no usable identity yet (not invitable)")
        }
        guard let notifications = contact.notifications, !notifications.isEmpty else {
            throw SwiftPadError.protocolError("inviteToTeam: contact has no notifications channel (worker requires it)")
        }
        guard contact.displayName != nil else {
            throw SwiftPadError.protocolError("inviteToTeam: contact has no displayName (roster requires a string displayName)")
        }
        var user: [String: Any] = [
            "curvePublic": contact.curvePublic,
            "notifications": notifications,
        ]
        if let v = contact.displayName { user["displayName"] = v }
        if let v = contact.edPublic { user["edPublic"] = v }
        if let v = contact.profile { user["profile"] = v }
        if let v = contact.avatar { user["avatar"] = v }
        if let v = contact.uid { user["uid"] = v }
        if let v = contact.badge { user["badge"] = v }
        _ = try await callAsData("__swiftpad.inviteToTeam", args: [teamId, user])
    }

    public func removeUser(teamId: String, curvePublic: String) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.requireTeamId(teamId, verb: "removeUser")
        guard !curvePublic.isEmpty else {
            throw SwiftPadError.protocolError("removeUser: curvePublic must be non-empty")
        }
        _ = try await callAsData("__swiftpad.removeUser", args: [teamId, curvePublic])
    }

    public func listContacts() async throws -> [String: Contact] {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        let data = try await callAsData("__swiftpad.listContacts", args: [])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let friends = obj["friends"] as? [String: Any],
              let pendingDict = obj["pending"] as? [String: Any] else {
            throw SwiftPadError.protocolError("listContacts: reply missing friends/pending objects")
        }
        var out: [String: Contact] = [:]
        for (curvePublic, raw) in pendingDict {
            guard let p = raw as? [String: Any] else { continue }
            out[curvePublic] = Contact(
                curvePublic: curvePublic,
                edPublic: nil,
                displayName: nil,
                notifications: p["channel"] as? String,
                profile: nil,
                avatar: nil,
                uid: nil,
                badge: nil,
                pending: true,
                hasDMChannel: false
            )
        }
        for (curvePublic, raw) in friends {
            guard let f = raw as? [String: Any] else { continue }
            out[curvePublic] = Contact(
                curvePublic: curvePublic,
                edPublic: f["edPublic"] as? String,
                displayName: f["displayName"] as? String,
                notifications: f["notifications"] as? String,
                profile: f["profile"] as? String,
                avatar: f["avatar"] as? String,
                uid: f["uid"] as? String,
                badge: f["badge"] as? String,
                pending: false,
                hasDMChannel: (f["channel"] as? String)?.isEmpty == false
            )
        }
        return out
    }

    public func listIncomingContactRequests() async throws -> [ContactRequest] {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        let data = try await callAsData("__swiftpad.listIncomingContactRequests", args: [])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRequests = obj["requests"] as? [[String: Any]] else {
            throw SwiftPadError.protocolError("listIncomingContactRequests: reply missing requests array")
        }
        var out: [ContactRequest] = []
        for raw in rawRequests {
            guard let hash = raw["hash"] as? String,
                  let author = raw["author"] as? String, !author.isEmpty else {
                throw SwiftPadError.protocolError("listIncomingContactRequests: entry missing hash/author")
            }
            let user = raw["user"] as? [String: Any] ?? [:]
            out.append(ContactRequest(
                hash: hash,
                from: Contact(
                    curvePublic: author,
                    edPublic: user["edPublic"] as? String,
                    displayName: user["displayName"] as? String,
                    notifications: user["notifications"] as? String,
                    profile: user["profile"] as? String,
                    avatar: user["avatar"] as? String,
                    uid: user["uid"] as? String,
                    badge: user["badge"] as? String,
                    pending: false,
                    hasDMChannel: false
                )
            ))
        }
        return out
    }

    public func listNotifications() async throws -> [MailboxNotification] {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        let data = try await callAsData("__swiftpad.listNotifications", args: [])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRows = obj["notifications"] as? [[String: Any]] else {
            throw SwiftPadError.protocolError("listNotifications: reply missing notifications array")
        }
        let out = try rawRows.map { try Self.decodeNotificationRow($0, verb: "listNotifications") }
        return out
    }

    public func markNotificationRead(box: String, hash: String) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard !box.isEmpty else {
            throw SwiftPadError.protocolError("markNotificationRead: box must not be empty")
        }
        guard !hash.isEmpty else {
            throw SwiftPadError.protocolError("markNotificationRead: hash must not be empty")
        }
        _ = try await callAsData("__swiftpad.markNotificationRead", args: [box, hash])
    }

    public func notificationHistory(box: String, count: Int, before: String? = nil)
        async throws -> NotificationHistoryPage {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard !box.isEmpty else {
            throw SwiftPadError.protocolError("notificationHistory: box must not be empty")
        }
        guard count > 0, count <= 100 else {
            throw SwiftPadError.protocolError("notificationHistory: count must be 1...100")
        }
        var args: [Any] = [box, count]
        if let before { args.append(before) }
        let data = try await callAsData("__swiftpad.notificationHistory", args: args)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exhausted = obj["exhausted"] as? Bool else {
            throw SwiftPadError.protocolError("notificationHistory: reply missing exhausted flag")
        }
        let rawRows = (obj["notifications"] as? [[String: Any]]) ?? []
        let out = try rawRows.map { try Self.decodeNotificationRow($0, verb: "notificationHistory") }
        return NotificationHistoryPage(
            notifications: out,
            exhausted: exhausted,
            unreadable: (obj["unreadable"] as? Int) ?? 0,
            oldestHash: obj["oldestHash"] as? String)
    }

    private static func decodeNotificationRow(_ raw: [String: Any],
                                              verb: String) throws -> MailboxNotification {
        guard let box = raw["box"] as? String,
              let hash = raw["hash"] as? String else {
            throw SwiftPadError.protocolError("\(verb): entry missing box/hash")
        }
        let time = (raw["time"] as? NSNumber).flatMap { n -> Date? in
            n.doubleValue > 0 ? Date(timeIntervalSince1970: n.doubleValue / 1000) : nil
        }
        return MailboxNotification(
            box: box,
            hash: hash,
            type: raw["type"] as? String ?? "",
            author: (raw["author"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            time: time,
            contentJSON: reserializeJSON(raw["content"], escapeSlashes: false) ?? "null")
    }

    public func sendContactRequest(curvePublic: String, notifications: String) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard !curvePublic.isEmpty else {
            throw SwiftPadError.protocolError("sendContactRequest: curvePublic must be non-empty")
        }
        guard !notifications.isEmpty else {
            throw SwiftPadError.protocolError("sendContactRequest: notifications channel must be non-empty")
        }
        _ = try await callAsData("__swiftpad.sendContactRequest", args: [curvePublic, notifications])
    }

    public func cancelContactRequest(curvePublic: String) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard !curvePublic.isEmpty else {
            throw SwiftPadError.protocolError("cancelContactRequest: curvePublic must be non-empty")
        }
        _ = try await callAsData("__swiftpad.cancelContactRequest", args: [curvePublic])
    }

    public func acceptContactRequest(_ request: ContactRequest) async throws {
        try await answerContactRequest(hash: request.hash, accept: true)
    }

    public func declineContactRequest(_ request: ContactRequest) async throws {
        try await answerContactRequest(hash: request.hash, accept: false)
    }

    private func answerContactRequest(hash: String, accept: Bool) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard !hash.isEmpty else {
            throw SwiftPadError.protocolError("answerContactRequest: request hash must be non-empty")
        }
        _ = try await callAsData("__swiftpad.answerContactRequest", args: [hash, accept])
    }

    public func removeContact(curvePublic: String) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard !curvePublic.isEmpty else {
            throw SwiftPadError.protocolError("removeContact: curvePublic must be non-empty")
        }
        _ = try await callAsData("__swiftpad.removeContact", args: [curvePublic])
    }


    public func createInviteLink(teamId: String, name: String, role: TeamRole,
                                 password: String? = nil, message: String? = nil) async throws -> URL {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        try Self.requireTeamId(teamId, verb: "createInviteLink")
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SwiftPadError.protocolError("createInviteLink: name must be non-blank (upstream link-create requires it)")
        }
        guard role == .viewer || role == .member else {
            throw SwiftPadError.protocolError("createInviteLink: role must be .viewer or .member (worker grants edit rights only for MEMBER; upstream UI offers no other roles)")
        }
        let data = try await callAsData("__swiftpad.createInviteLink",
                                        args: [teamId, name, role.wireValue, password ?? "", message ?? ""])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hash = obj["hash"] as? String else {
            throw SwiftPadError.protocolError("createInviteLink: reply missing hash")
        }
        let origin = serverOrigin()
        guard let url = URL(string: "\(origin)/teams/#\(hash)") else {
            throw SwiftPadError.protocolError("createInviteLink: could not compose invite URL")
        }
        return url
    }

    public func previewInviteLink(_ url: URL) async throws -> InvitePreview {
        let fragment = try Self.requireInviteFragment(url, verb: "previewInviteLink")
        let data = try await callAsData("__swiftpad.previewInviteLink", args: [fragment])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let teamName = obj["teamName"] as? String,
              let requiresPassword = obj["requiresPassword"] as? Bool else {
            throw SwiftPadError.protocolError("previewInviteLink: reply missing preview fields")
        }
        return InvitePreview(
            teamName: teamName,
            message: obj["message"] as? String,
            authorDisplayName: obj["authorDisplayName"] as? String,
            requiresPassword: requiresPassword
        )
    }

    public func acceptInviteLink(_ url: URL, password: String? = nil) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        let fragment = try Self.requireInviteFragment(url, verb: "acceptInviteLink")
        _ = try await callAsData("__swiftpad.acceptInviteLink", args: [fragment, password ?? ""])
    }

    private func serverOrigin() -> String {
        serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func requireInviteFragment(_ url: URL, verb: String) throws -> String {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
              !fragment.isEmpty else {
            throw SwiftPadError.protocolError("\(verb): URL has no #fragment (expected <origin>/teams/#/2/invite/edit/…)")
        }
        guard fragment.count <= 42 else {
            throw SwiftPadError.protocolError("\(verb): fragment is \(fragment.count) chars — not an invite fragment (expected ≤ 42)")
        }
        return fragment
    }

    public func getDeletedPads(candidates: [String]) async throws -> [String] {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        struct Envelope: Decodable { let channels: [String] }
        let env: Envelope = try await callAndDecode("__swiftpad.getDeletedPads", args: [candidates])
        return env.channels
    }

    public func getShareLinks(channel: String) async throws -> ShareLinks {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        struct BridgeShape: Decodable {
            let type: String
            let editHash: String?
            let viewHash: String
        }
        let shape: BridgeShape = try await callAndDecode("__swiftpad.getShareLinks", args: [channel])
        let origin = serverOrigin()
        let editUrl = shape.editHash.map { "\(origin)/\(shape.type)/#\($0)" }
        let viewUrl = "\(origin)/\(shape.type)/#\(shape.viewHash)"
        let presentUrl = "\(viewUrl)present/"
        let embedUrl = "\(viewUrl)embed/"
        return ShareLinks(edit: editUrl, view: viewUrl, present: presentUrl, embed: embedUrl)
    }

    public func getAccountInfo() async throws -> AccountInfo {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        struct BridgeShape: Decodable {
            let edPublic: String?
            let curvePublic: String?
            let profileViewHash: String?
            let notifications: String?
        }
        let shape: BridgeShape = try await callAndDecode("__swiftpad.getAccountInfo", args: [])
        guard let edPub = shape.edPublic, let curvePub = shape.curvePublic else {
            throw SwiftPadError.protocolError(
                "getAccountInfo: missing edPublic or curvePublic on authenticated session — worker bug?")
        }
        let origin = serverOrigin()
        let profileUrl = shape.profileViewHash.map { "\(origin)/profile/#\($0)" }
        return AccountInfo(edPublic: edPub, curvePublic: curvePub, profileUrl: profileUrl,
                           notifications: shape.notifications)
    }

    public func getProfile() async throws -> UserProfile {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        return try await callAndDecode("__swiftpad.getProfile", args: [])
    }

    @discardableResult
    public func setProfileDescription(_ text: String) async throws -> UserProfile {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        return try await callAndDecode("__swiftpad.setProfileDescription", args: [text])
    }

    @discardableResult
    public func setProfileUrl(_ url: String) async throws -> UserProfile {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        return try await callAndDecode("__swiftpad.setProfileUrl", args: [url])
    }

    private static let avatarMimeTypes: Set<String> =
        ["image/png", "image/jpeg", "image/jpg", "image/webp", "image/gif"]

    private static let avatarMaxPlaintextBytes = 500_000

    public func setAvatar(imageData: Data, mimeType: String) async throws -> DriveEntry {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard Self.avatarMimeTypes.contains(mimeType.lowercased()) else {
            throw SwiftPadError.protocolError(
                "setAvatar: mimeType '\(mimeType)' not allowed — upstream accepts \(Self.avatarMimeTypes.sorted().joined(separator: ", "))")
        }
        guard !imageData.isEmpty else {
            throw SwiftPadError.protocolError("setAvatar: imageData is empty")
        }
        guard imageData.count <= Self.avatarMaxPlaintextBytes else {
            throw SwiftPadError.protocolError(
                "setAvatar: \(imageData.count) bytes exceeds \(Self.avatarMaxPlaintextBytes) — the web client hides avatars whose blob exceeds 512 KiB (renders initials); crop/resize before upload")
        }
        let entry = try await uploadFile(
            plaintext: imageData, name: "avatar", mimeType: mimeType.lowercased(),
            title: "avatar")
        _ = try await callAsData("__swiftpad.setProfileAvatar", args: [entry.href])
        return entry
    }

    @discardableResult
    public func removeAvatar() async throws -> UserProfile {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        return try await callAndDecode("__swiftpad.setProfileAvatar", args: [""])
    }

    public func createPad(title: String, type: String = "pad") async throws -> CreatedPad {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        return try await callAndDecode("__swiftpad.createPad", args: [title, type])
    }

    public func deletePad(channel: String) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await callAsData("__swiftpad.deletePad", args: [channel])
    }

    public func destroyPad(channel: String) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await callAsData("__swiftpad.destroyPad", args: [channel])
    }

    public func setPadTitle(channel: String, title: String) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await callAsData("__swiftpad.setPadTitle", args: [channel, title])
    }

    public func pinPads(_ channels: [String]) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await callAsData("__swiftpad.pinPads", args: [channels])
    }

    public func unpinPads(_ channels: [String]) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await callAsData("__swiftpad.unpinPads", args: [channels])
    }

    public func getPadMetadata(channel: String) async throws -> PadMetadata {
        guard channel.count == 32, channel.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
            throw SwiftPadError.protocolError("channel must be 32 lowercase-hex chars; got '\(channel)' (\(channel.count))")
        }
        let data = try await callAsData("__swiftpad.getPadMetadata", args: [channel])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwiftPadError.protocolError("getPadMetadata: non-JSON payload")
        }
        let channelOut = (obj["channel"] as? String) ?? channel
        let metadataStr: String
        if let md = obj["metadata"],
           let d = try? JSONSerialization.data(withJSONObject: md),
           let s = String(data: d, encoding: .utf8) {
            metadataStr = s
        } else {
            metadataStr = "{}"
        }
        return PadMetadata(channel: channelOut, metadata: metadataStr)
    }

    public func getPadContent(channel: String, cache: PadDocumentCache? = nil, userKey: Data = Data()) async throws -> PadContent {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard channel.count == 32, channel.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
            throw SwiftPadError.protocolError("getPadContent: channel must be 32 lowercase-hex chars; got '\(channel)' (\(channel.count))")
        }

        var cachedEntry: PadCacheEntry? = nil
        if let cache = cache {
            cachedEntry = try? await cache.fetch(channel: channel, userKey: userKey)
        }

        let response: GetPadContentResponse
        do {
            response = try await fetchPadContentRaw(
                channel: channel,
                lastKnownHash: cachedEntry?.anchorCheckpointWireHash
            )
        } catch let err as JSBridgeError {
            if case .jsRejection(let msg) = err, msg.contains("EUNKNOWN"), cachedEntry != nil {
                Trace.info(.session, "getPadContent: cached anchor not found (EUNKNOWN) — retrying without anchor")
                do {
                    response = try await fetchPadContentRaw(channel: channel, lastKnownHash: nil)
                } catch {
                    throw Self.mapBridgeError(error)
                }
            } else {
                throw Self.mapBridgeError(err)
            }
        }

        if let cached = cachedEntry,
           response.applied == 1,
           let firstApplied = response.firstAppliedWireHash,
           firstApplied == cached.anchorCheckpointWireHash {
            return PadContent(
                channel: channel,
                type: response.type,
                raw: cached.userDoc,
                decoded: try Self.decodePadContentDispatch(type: response.type, raw: cached.userDoc)
            )
        }

        if let cache = cache, let checkpointHash = response.lastAppliedCheckpointWireHash {
            do {
                try await cache.store(
                    channel: channel,
                    anchorCheckpointWireHash: checkpointHash,
                    userDoc: response.raw,
                    userKey: userKey
                )
            } catch {
                Trace.warn(.session, "getPadContent: cache write-back failed: \(error)")
            }
        }

        return PadContent(
            channel: channel,
            type: response.type,
            raw: response.raw,
            decoded: try Self.decodePadContentDispatch(type: response.type, raw: response.raw)
        )
    }

    public func warmPadCache(channel: String, cache: PadDocumentCache, userKey: Data = Data()) async throws {
        _ = try await getPadContent(channel: channel, cache: cache, userKey: userKey)
    }

    public func streamFileContent(channel: String, maxBytes: Int? = nil) async throws -> FileBlobStream {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard channel.count == 48, channel.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
            throw SwiftPadError.protocolError("streamFileContent: channel must be 48 lowercase-hex chars (file-type); got '\(channel)' (\(channel.count))")
        }

        let openJSON: String
        do {
            openJSON = try await bridge.callAsync("__swiftpad.streamFileContent_open", args: [channel])
        } catch {
            throw Self.mapBridgeError(error)
        }
        guard let openData = openJSON.data(using: .utf8),
              let openObj = try? JSONSerialization.jsonObject(with: openData) as? [String: Any] else {
            throw SwiftPadError.protocolError("streamFileContent: non-JSON open response")
        }
        if let errCode = openObj["error"] as? String {
            var details: [String: String]? = nil
            if let errType = openObj["errorType"] as? String {
                details = ["errorType": errType]
            }
            if errCode == "PROTOCOL" {
                throw SwiftPadError.protocolError("streamFileContent: \(details?["errorType"] ?? "protocol error")")
            }
            throw SwiftPadError.workerError(code: errCode, details: details)
        }
        guard let handle = openObj["handle"] as? Int,
              let metaObj = openObj["metadata"] as? [String: Any],
              let name = metaObj["name"] as? String,
              let mimeType = metaObj["mimeType"] as? String,
              let driveTitle = metaObj["driveTitle"] as? String else {
            if let orphan = openObj["handle"] as? Int {
                _ = try? await bridge.callAsync("__swiftpad.streamFileContent_close", args: [orphan])
            }
            throw SwiftPadError.protocolError("streamFileContent: open response missing handle/metadata fields")
        }
        let metadata = FileBlobMetadata(name: name, mimeType: mimeType, driveTitle: driveTitle)

        let puller = FileStreamPuller(bridge: bridge, handle: handle, maxBytes: maxBytes)
        let stream = AsyncThrowingStream<Data, Error>(unfolding: {
            try await puller.next()
        })

        return FileBlobStream(channel: channel, metadata: metadata, chunks: stream)
    }

    public func uploadFile(
        plaintext: AsyncStream<Data>,
        totalBytes: Int? = nil,
        name: String,
        mimeType: String,
        title: String? = nil,
        path: [String] = [],
        progress: (@Sendable (FileUploadProgress) -> Void)? = nil
    ) async throws -> DriveEntry {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard !name.isEmpty else { throw SwiftPadError.protocolError("uploadFile: name must be non-empty") }
        guard !mimeType.isEmpty else { throw SwiftPadError.protocolError("uploadFile: mimeType must be non-empty") }
        if let cap = totalBytes, cap > BridgeLimits.maxFileBlobUploadBytes {
            throw SwiftPadError.protocolError("uploadFile: totalBytes=\(cap) exceeds maxFileBlobUploadBytes=\(BridgeLimits.maxFileBlobUploadBytes)")
        }

        let openJSON: String
        do {
            openJSON = try await bridge.callAsync("__swiftpad.uploadFile_open", args: [name, mimeType])
        } catch {
            throw Self.mapBridgeError(error)
        }
        guard let openData = openJSON.data(using: .utf8),
              let openObj = try? JSONSerialization.jsonObject(with: openData) as? [String: Any] else {
            throw SwiftPadError.protocolError("uploadFile: non-JSON open response")
        }
        if let errCode = openObj["error"] as? String {
            var details: [String: String]? = nil
            if let errType = openObj["errorType"] as? String { details = ["errorType": errType] }
            if errCode == "PROTOCOL" {
                throw SwiftPadError.protocolError("uploadFile: \(details?["errorType"] ?? "protocol error")")
            }
            if errCode == "NOT_AUTHENTICATED" {
                throw SwiftPadError.notAuthenticated
            }
            throw SwiftPadError.workerError(code: errCode, details: details)
        }
        guard let handle = openObj["handle"] as? Int,
              let plainChunkSize = openObj["plainChunkSize"] as? Int else {
            if let orphan = openObj["handle"] as? Int {
                _ = try? await bridge.callAsync("__swiftpad.uploadFile_cancel", args: [orphan])
            }
            throw SwiftPadError.protocolError("uploadFile: open response missing handle/plainChunkSize")
        }

        let batchMax = 4
        var buffer = Data()
        buffer.reserveCapacity(plainChunkSize)
        var pendingBatch: [String] = []
        var bytesUploaded = 0
        let estimateFn: (Int) -> Int = { uploaded in
            return totalBytes ?? uploaded
        }

        func sendBatch(_ chunks: [String], isFinal: Bool) async throws {
            if chunks.isEmpty { return }
            let writeJSON: String
            do {
                writeJSON = try await bridge.callAsync(
                    "__swiftpad.uploadFile_writeChunks",
                    args: [handle, chunks, isFinal]
                )
            } catch {
                throw Self.mapBridgeError(error)
            }
            guard let wData = writeJSON.data(using: .utf8),
                  let wObj = try? JSONSerialization.jsonObject(with: wData) as? [String: Any] else {
                throw SwiftPadError.protocolError("uploadFile: non-JSON writeChunks response")
            }
            if let errCode = wObj["error"] as? String {
                var details: [String: String]? = nil
                if let errType = wObj["errorType"] as? String { details = ["errorType": errType] }
                if errCode == "PROTOCOL" {
                    throw SwiftPadError.protocolError("uploadFile: \(details?["errorType"] ?? "protocol error")")
                }
                throw SwiftPadError.workerError(code: errCode, details: details)
            }
            if let prog = wObj["progress"] as? [String: Any], let bu = prog["bytesUploaded"] as? Int {
                bytesUploaded = bu
                progress?(FileUploadProgress(bytesUploaded: bu, bytesEstimate: estimateFn(bu)))
            }
        }

        do {
            for try await chunk in plaintext {
                try Task.checkCancellation()
                buffer.append(chunk)
                while buffer.count >= plainChunkSize {
                    let next = buffer.prefix(plainChunkSize)
                    buffer.removeFirst(plainChunkSize)
                    pendingBatch.append(next.base64EncodedString())
                    if pendingBatch.count > batchMax {
                        let toFlush = Array(pendingBatch.prefix(batchMax))
                        pendingBatch.removeFirst(batchMax)
                        try await sendBatch(toFlush, isFinal: false)
                    }
                }
            }
            try Task.checkCancellation()
            if !buffer.isEmpty {
                if !pendingBatch.isEmpty {
                    try await sendBatch(pendingBatch, isFinal: false)
                    pendingBatch.removeAll(keepingCapacity: false)
                }
                let terminal = buffer.base64EncodedString()
                buffer.removeAll(keepingCapacity: false)
                try await sendBatch([terminal], isFinal: true)
            } else if !pendingBatch.isEmpty {
                let terminalChunk = pendingBatch.removeLast()
                if !pendingBatch.isEmpty {
                    try await sendBatch(pendingBatch, isFinal: false)
                    pendingBatch.removeAll(keepingCapacity: false)
                }
                try await sendBatch([terminalChunk], isFinal: true)
            } else {
                throw SwiftPadError.protocolError("uploadFile: empty plaintext stream — at least one byte required")
            }
        } catch {
            _ = try? await bridge.callAsync("__swiftpad.uploadFile_cancel", args: [handle])
            throw error
        }

        if Task.isCancelled {
            _ = try? await bridge.callAsync("__swiftpad.uploadFile_cancel", args: [handle])
            throw CancellationError()
        }
        let resolvedTitle = title ?? name
        let finalizeJSON: String
        do {
            finalizeJSON = try await bridge.callAsync(
                "__swiftpad.uploadFile_finalize",
                args: [handle, resolvedTitle, path]
            )
        } catch {
            _ = try? await bridge.callAsync("__swiftpad.uploadFile_cancel", args: [handle])
            throw Self.mapBridgeError(error)
        }
        guard let fData = finalizeJSON.data(using: .utf8),
              let fObj = try? JSONSerialization.jsonObject(with: fData) as? [String: Any] else {
            throw SwiftPadError.protocolError("uploadFile: non-JSON finalize response")
        }
        if let errCode = fObj["error"] as? String {
            var details: [String: String] = [:]
            if let errType = fObj["errorType"] as? String { details["errorType"] = errType }
            if let orphan = fObj["partialUploadOrphanChannel"] as? String { details["partialUploadOrphanChannel"] = orphan }
            _ = try? await bridge.callAsync("__swiftpad.uploadFile_cancel", args: [handle])
            if errCode == "PROTOCOL" {
                throw SwiftPadError.protocolError("uploadFile: \(details["errorType"] ?? "protocol error")")
            }
            throw SwiftPadError.workerError(code: errCode, details: details.isEmpty ? nil : details)
        }
        guard let entryDict = fObj["driveEntry"] as? [String: Any] else {
            throw SwiftPadError.protocolError("uploadFile: finalize missing driveEntry")
        }
        let entryData = try JSONSerialization.data(withJSONObject: entryDict)
        let entry: DriveEntry
        do {
            entry = try JSONDecoder().decode(DriveEntry.self, from: entryData)
        } catch {
            throw SwiftPadError.protocolError("uploadFile: driveEntry decode failed: \(error)")
        }
        progress?(FileUploadProgress(bytesUploaded: bytesUploaded, bytesEstimate: estimateFn(bytesUploaded)))
        return entry
    }

    public func uploadFile(
        plaintext: Data,
        name: String,
        mimeType: String,
        title: String? = nil,
        path: [String] = [],
        progress: (@Sendable (FileUploadProgress) -> Void)? = nil
    ) async throws -> DriveEntry {
        let chunkSize = BridgeLimits.uploadPlainChunkSize
        let total = plaintext.count
        let stream = AsyncStream<Data> { continuation in
            var offset = 0
            while offset < total {
                let end = min(offset + chunkSize, total)
                continuation.yield(plaintext.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
        return try await uploadFile(
            plaintext: stream,
            totalBytes: total,
            name: name,
            mimeType: mimeType,
            title: title,
            path: path,
            progress: progress
        )
    }

    struct GetPadContentResponse {
        let type: String
        let raw: String
        let applied: Int
        let firstAppliedWireHash: String?
        let lastAppliedCheckpointWireHash: String?
    }

    private func fetchPadContentRaw(channel: String, lastKnownHash: String?) async throws -> GetPadContentResponse {
        let args: [Any] = (lastKnownHash != nil) ? [channel, lastKnownHash!] : [channel]
        let json = try await bridge.callAsync("__swiftpad.getPadContent", args: args)
        let data = Data(json.utf8)
        try Self.checkWorkerEnvelope(data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwiftPadError.protocolError("getPadContent: non-JSON payload")
        }
        guard let typeStr = obj["type"] as? String,
              let raw = obj["raw"] as? String else {
            throw SwiftPadError.protocolError("getPadContent: missing type/raw fields")
        }
        guard let applied = obj["applied"] as? Int else {
            throw SwiftPadError.protocolError("getPadContent: missing applied field (wire contract)")
        }
        let firstAppliedWireHash = obj["firstAppliedWireHash"] as? String
        let lastAppliedCheckpointWireHash = obj["lastAppliedCheckpointWireHash"] as? String
        return GetPadContentResponse(
            type: typeStr,
            raw: raw,
            applied: applied,
            firstAppliedWireHash: firstAppliedWireHash,
            lastAppliedCheckpointWireHash: lastAppliedCheckpointWireHash
        )
    }

    private static func decodePadContentDispatch(type: String, raw: String) throws -> PadContent.Decoded {
        switch type {
        case "pad":
            return .pad
        case "code":
            return .code(try Self.parseCodePadContent(raw: raw))
        case "slide":
            return .slide(try Self.parseSlidePadContent(raw: raw))
        default:
            return .unknown
        }
    }

    public func setPadContent(channel: String, raw: String, cache: PadDocumentCache? = nil) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard channel.count == 32, channel.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
            throw SwiftPadError.protocolError("setPadContent: channel must be 32 lowercase-hex chars; got '\(channel)' (\(channel.count))")
        }

        _ = try await callAsData("__swiftpad.setPadContent", args: [channel, raw])

        if let cache {
            try? await cache.evict(channel: channel)
        }
    }

    private static func parseCodePadContent(raw: String) throws -> CodePadContent {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwiftPadError.protocolError("decodePadContent: code pad raw is not a JSON object")
        }
        let content = (obj["content"] as? String) ?? ""
        let highlightMode = (obj["highlightMode"] as? String) ?? ""
        let authormarks = reserialize(obj["authormarks"])
        let metadata = reserialize(obj["metadata"])
        return CodePadContent(content: content,
                              highlightMode: highlightMode,
                              authormarks: authormarks,
                              metadata: metadata)
    }

    private static func parseSlidePadContent(raw: String) throws -> SlidePadContent {
        if raw.isEmpty || raw == "\"\"" { return SlidePadContent(content: "", metadata: nil) }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwiftPadError.protocolError("decodePadContent: slide pad raw is not a JSON object")
        }
        let content = (obj["content"] as? String) ?? ""
        let metadata = reserialize(obj["metadata"])
        return SlidePadContent(content: content, metadata: metadata)
    }

    public func openPadSession(channel: String,
                               delegate: PadSessionDelegate) async throws -> PadSession {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard channel.count == 32, channel.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
            throw SwiftPadError.protocolError("openPadSession: channel must be 32 lowercase-hex chars; got '\(channel)' (\(channel.count))")
        }

        let data = try await callAsData("__swiftpad.openPadSession", args: [channel])

        let obj: [String: Any]
        let sessionId: String
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SwiftPadError.protocolError("openPadSession reply not a JSON object")
            }
            obj = parsed
            guard let sid = parsed["sessionId"] as? String else {
                throw SwiftPadError.protocolError("openPadSession reply missing sessionId")
            }
            sessionId = sid
        } catch {
            throw error is SwiftPadError ? error : SwiftPadError.protocolError("openPadSession reply parse failed: \(error)")
        }

        guard let initialRaw = obj["initialRaw"] as? String,
              let typeStr = obj["type"] as? String else {
            _ = try? await bridge.callAsync("__swiftpad.closePadSession", args: [sessionId])
            throw SwiftPadError.protocolError("openPadSession reply missing required fields")
        }
        let readOnly = (obj["readOnly"] as? Bool) ?? false

        let decoded: PadContent.Decoded
        do {
            decoded = try Self.decodePadContentDispatch(type: typeStr, raw: initialRaw)
        } catch {
            _ = try? await bridge.callAsync("__swiftpad.closePadSession", args: [sessionId])
            throw error
        }

        let initialContent = PadContent(channel: channel,
                                        type: typeStr,
                                        raw: initialRaw,
                                        decoded: decoded)

        let session = PadSession(sessionId: sessionId,
                                 channel: channel,
                                 initialContent: initialContent,
                                 readOnly: readOnly,
                                 bridge: bridge,
                                 owner: self,
                                 delegate: delegate)
        registerPadSession(session)
        do {
            _ = try await callAsData("__swiftpad.confirmPadSession", args: [sessionId])
        } catch {
            unregisterPadSession(sessionId: sessionId)
            _ = try? await bridge.callAsync("__swiftpad.closePadSession", args: [sessionId])
            throw error
        }
        return session
    }

    public func openPadChat(channel: String,
                            delegate: PadChatSessionDelegate) async throws -> PadChatSession {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard channel.count == 32, channel.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
            throw SwiftPadError.protocolError("openPadChat: channel must be 32 lowercase-hex chars; got '\(channel)' (\(channel.count))")
        }

        let opened = try await Self.chatVerbObject(bridge: bridge,
                                                   path: "__swiftpad.openPadChat",
                                                   args: [channel])
        guard let chatSessionId = opened["chatSessionId"] as? String else {
            throw SwiftPadError.protocolError("openPadChat reply missing chatSessionId")
        }
        guard let chatChannel = opened["chatChannel"] as? String else {
            _ = try? await bridge.callAsync("__swiftpad.closePadChat", args: [chatSessionId])
            throw SwiftPadError.protocolError("openPadChat reply missing chatChannel")
        }

        let box = ChatRouteBox()
        registerChatRoute(chatChannel: chatChannel, box: box)

        let rooms: [String: Any]
        do {
            rooms = try await Self.chatVerbObject(bridge: bridge,
                                                  path: "__swiftpad.chatRooms",
                                                  args: [chatSessionId])
        } catch {
            unregisterChatRoute(chatChannel: chatChannel)
            _ = try? await bridge.callAsync("__swiftpad.closePadChat", args: [chatSessionId])
            throw error
        }
        let snapshot = PadChatSession.decodeMessagesArray(rooms, context: "openPadChat")

        let session = PadChatSession(chatSessionId: chatSessionId,
                                     chatChannel: chatChannel,
                                     padChannel: channel,
                                     initialMessages: snapshot,
                                     bridge: bridge,
                                     owner: self,
                                     delegate: delegate)
        let seen = Set(snapshot.map { $0.sig })
        bridge.queue.async {
            let (buffered, clearPending) = box.promote(to: session)
            for message in buffered where !seen.contains(message.sig) {
                session.dispatchMessage(message)
            }
            if clearPending { session.dispatchClear() }
        }
        return session
    }

    public func openDirectMessages(with contactCurvePublic: String,
                                   delegate: DMChannelDelegate) async throws -> DMChannel {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        guard !contactCurvePublic.isEmpty else {
            throw SwiftPadError.protocolError("openDirectMessages: contactCurvePublic must be non-empty")
        }

        let opened = try await Self.chatVerbObject(bridge: bridge,
                                                   path: "__swiftpad.openDMChannel",
                                                   args: [contactCurvePublic],
                                                   timeoutSeconds: 100)
        guard let dmSessionId = opened["dmSessionId"] as? String else {
            throw SwiftPadError.protocolError("openDMChannel reply missing dmSessionId")
        }
        guard let channel = opened["channel"] as? String else {
            _ = try? await bridge.callAsync("__swiftpad.closeDMChannel", args: [dmSessionId])
            throw SwiftPadError.protocolError("openDMChannel reply missing channel")
        }

        let box = ChatRouteBox()
        registerChatRoute(chatChannel: channel, box: box)
        registerDMContact(curvePublic: contactCurvePublic, channel: channel)

        let rooms: [String: Any]
        do {
            rooms = try await Self.chatVerbObject(bridge: bridge,
                                                  path: "__swiftpad.dmRooms",
                                                  args: [dmSessionId])
        } catch {
            unregisterChatRoute(chatChannel: channel)
            unregisterDMContact(curvePublic: contactCurvePublic)
            _ = try? await bridge.callAsync("__swiftpad.closeDMChannel", args: [dmSessionId])
            throw error
        }
        let snapshot = PadChatSession.decodeMessagesArray(rooms, context: "openDirectMessages")

        let dm = DMChannel(dmSessionId: dmSessionId,
                           contactCurvePublic: contactCurvePublic,
                           channelId: channel,
                           initialMessages: snapshot,
                           bridge: bridge,
                           owner: self,
                           delegate: delegate)
        let seen = Set(snapshot.map { $0.sig })
        bridge.queue.async {
            let (buffered, clearPending) = box.promote(to: dm)
            for message in buffered where !seen.contains(message.sig) {
                dm.dispatchMessage(message)
            }
            if clearPending { dm.dispatchClear() }
        }
        return dm
    }

    static func chatVerbObject(bridge: JSBridge, path: String, args: [Any],
                               timeoutSeconds: TimeInterval = BridgeLimits.callAsyncTimeoutSeconds) async throws -> [String: Any] {
        let json: String
        do {
            json = try await bridge.callAsync(path, args: args, timeoutSeconds: timeoutSeconds)
        } catch {
            throw mapBridgeError(error)
        }
        let data = Data(json.utf8)
        do {
            try checkWorkerEnvelope(data)
        } catch {
            if case SwiftPadError.workerError(let code, _) = error,
               let chatError = PadChatError(rawValue: code) {
                throw chatError
            }
            throw error
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwiftPadError.protocolError("\(path) reply not a JSON object")
        }
        return obj
    }

    private static func reserialize(_ value: Any?) -> String? {
        reserializeJSON(value, escapeSlashes: true)
    }


    private func callAsData(_ jsPath: String, args: [Any]) async throws -> Data {
        let json: String
        do {
            json = try await bridge.callAsync(jsPath, args: args)
        } catch {
            throw Self.mapBridgeError(error)
        }
        let data = Data(json.utf8)
        try Self.checkWorkerEnvelope(data)
        return data
    }

    private func callAndDecode<T: Decodable>(_ jsPath: String, args: [Any]) async throws -> T {
        let data = try await callAsData(jsPath, args: args)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Self.mapBridgeError(error)
        }
    }


    static func mapBridgeError(_ error: Error) -> Error {
        switch error {
        case JSBridgeError.bridgeClosed:
            return SwiftPadError.bridgeClosed
        case JSBridgeError.callTimeout(let path):
            return SwiftPadError.timeout(path)
        case JSBridgeError.jsRejection(let message):
            if let r = message.range(of: "^PAD_[A-Z_]+_FAILED(?=:)", options: .regularExpression) {
                let code = String(message[r])
                let detail = String(message[message.index(after: r.upperBound)...])
                return SwiftPadError.workerError(code: code,
                                                 details: detail.isEmpty ? nil : ["errorType": detail])
            }
            return SwiftPadError.internalError("bridge: \(JSBridgeError.jsRejection(message))")
        case let bridgeError as JSBridgeError:
            return SwiftPadError.internalError("bridge: \(bridgeError)")
        case let decodeError as DecodingError:
            return SwiftPadError.internalError("decode: \(decodeError)")
        default:
            return error
        }
    }

    static func checkWorkerEnvelope(_ data: Data) throws {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sentinel = obj["error"] as? String, !sentinel.isEmpty else { return }
        let allowed: Set<String> = ["error", "errorType", "code"]
        guard Set(obj.keys).isSubset(of: allowed) else { return }
        var details: [String: String] = [:]
        if let errorType = obj["errorType"] as? String { details["errorType"] = errorType }
        if let code = obj["code"], !(code is NSNull) {
            details["code"] = (code as? String) ?? ((code as? NSNumber)?.stringValue ?? String(describing: code))
        }
        throw SwiftPadError.workerError(code: sentinel, details: details.isEmpty ? nil : details)
    }

    enum WebsocketPathDisposition: Equatable {
        case notWsAbsolute
        case admissible(Origin)
        case rejected(detail: String)
    }

    static func classifyWebsocketPath(serverURL: URL, apiConfig: [String: Any]) -> WebsocketPathDisposition {
        guard let anyValue = apiConfig["websocketPath"] else { return .notWsAbsolute }
        if anyValue is NSNull { return .notWsAbsolute }
        if let n = anyValue as? NSNumber, n == 0 { return .notWsAbsolute }
        guard let raw = anyValue as? String else {
            return .rejected(detail:
                "server config websocketPath is present but not a string (\(type(of: anyValue))) — refusing")
        }
        let bytes = Array(raw.utf8)
        let wssPrefix = Array("wss://".utf8), wsPrefix = Array("ws://".utf8)
        let schemeLen: Int
        let isPlaintextWs: Bool
        if bytes.starts(with: wssPrefix) {
            schemeLen = wssPrefix.count; isPlaintextWs = false
        } else if bytes.starts(with: wsPrefix) {
            schemeLen = wsPrefix.count; isPlaintextWs = true
        } else {
            return .notWsAbsolute
        }
        let delims: Set<UInt8> = [UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#")]
        let authorityEnd = bytes[schemeLen...].firstIndex(where: { delims.contains($0) }) ?? bytes.count
        let authority = bytes[schemeLen..<authorityEnd]
        if authority.contains(UInt8(ascii: "@")) {
            let hostPart = authority.split(separator: UInt8(ascii: "@"),
                                           omittingEmptySubsequences: false).last
                .map { String(decoding: $0, as: UTF8.self) } ?? "?"
            return .rejected(detail:
                "server config websocketPath embeds credentials (userinfo) before host '\(sanitizeDetail(String(hostPart.prefix(200))))' — refusing")
        }
        guard let serverOrigin = Origin(url: serverURL) else {
            return .rejected(detail:
                "cannot verify websocketPath — serverURL has no parseable origin")
        }
        guard let origin = Origin(string: raw) else {
            return .rejected(detail:
                "server config points its websocket at '\(sanitizeDetail(String(raw.prefix(200))))', whose origin cannot be parsed — refusing")
        }
        if isPlaintextWs && isPlaintextNonLoopback(origin) {
            return .rejected(detail:
                "server config points its websocket at ws://\(sanitizeDetail(String(origin.host.prefix(200)))) — plaintext ws to a non-loopback host refused (wss required)")
        }
        guard sameRegistrableDomain(origin.host, serverOrigin.host) else {
            return .rejected(detail:
                "server config points its websocket at \(origin.scheme)://\(sanitizeDetail(String(origin.host.prefix(200)))):\(origin.port), outside \(serverOrigin.host)'s domain — refusing per same-domain policy")
        }
        return .admissible(origin)
    }

    private static func sanitizeDetail(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter {
            !($0.value < 0x20 || (0x7F...0x9F).contains($0.value))
        }))
    }

    static func isPlaintextNonLoopback(_ origin: Origin) -> Bool {
        guard origin.scheme == "http" || origin.scheme == "ws" else { return false }
        return !isLoopbackHost(origin.host)
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        return host == "localhost" || host == "127.0.0.1"
            || host == "::1" || host == "[::1]"
    }

    static func requireAdmissibleWebsocketPath(serverURL: URL, apiConfig: [String: Any]) throws {
        if case .rejected(let detail) = classifyWebsocketPath(serverURL: serverURL, apiConfig: apiConfig) {
            throw SwiftPadError.serverConfigRejected(detail: detail)
        }
    }

    static func deriveAllowedOrigins(serverURL: URL, apiConfig: [String: Any]) -> Set<Origin> {
        var origins: Set<Origin> = []
        func add(_ origin: Origin) {
            origins.insert(origin)
            let mirror: String? = {
                switch origin.scheme {
                case "http":  return "ws"
                case "https": return "wss"
                case "ws":    return "http"
                case "wss":   return "https"
                default:      return nil
                }
            }()
            if let mScheme = mirror,
               let url = URL(string: "\(mScheme)://\(origin.host):\(origin.port)"),
               let mirrored = Origin(url: url) {
                origins.insert(mirrored)
            }
        }
        guard let serverOrigin = Origin(url: serverURL) else { return [] }
        add(serverOrigin)
        for key in ["httpUnsafeOrigin", "fileHost"] {
            guard let s = apiConfig[key] as? String, let o = Origin(string: s) else { continue }
            guard sameRegistrableDomain(o.host, serverOrigin.host) else {
                Trace.warn(.session, "rejecting apiConfig.\(key) (host=\(o.host)) — does not share a registrable domain with serverURL (host=\(serverOrigin.host))")
                continue
            }
            if key == "fileHost", isPlaintextNonLoopback(o) {
                Trace.warn(.session, "rejecting apiConfig.fileHost (host=\(o.host)) — plaintext http to a non-loopback host would expose the login block and TOTP bearer")
                continue
            }
            add(o)
        }
        switch classifyWebsocketPath(serverURL: serverURL, apiConfig: apiConfig) {
        case .admissible(let o):
            add(o)
        case .rejected(let detail):
            Trace.warn(.session, "rejecting apiConfig.websocketPath — \(detail)")
        case .notWsAbsolute:
            break
        }
        return origins
    }

    static func sameRegistrableDomain(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return false }
        if a == "localhost" || b == "localhost" { return false }
        if isIPAddress(a) || isIPAddress(b) { return false }
        func lastTwoLabels(_ h: String) -> String {
            let parts = h.split(separator: ".")
            guard parts.count >= 2 else { return h }
            return parts.suffix(2).joined(separator: ".")
        }
        return lastTwoLabels(a).lowercased() == lastTwoLabels(b).lowercased()
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let labels = host.split(separator: ".")
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return true }
        return false
    }

    static func requireHTTPUnsafeOrigin(_ apiConfig: [String: Any]) throws {
        let origin = (apiConfig["httpUnsafeOrigin"] as? String) ?? ""
        guard !origin.isEmpty else {
            throw SwiftPadError.protocolError(
                "server /api/config is missing httpUnsafeOrigin — CryptPad deployment appears misconfigured")
        }
        guard let url = URL(string: origin) else {
            throw SwiftPadError.protocolError(
                "server httpUnsafeOrigin is not a parseable URL: \(origin)")
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host ?? ""
        if scheme == "http" && !isLoopbackHost(host) {
            throw SwiftPadError.protocolError(
                "server httpUnsafeOrigin must use https:// for non-loopback hosts (got \(scheme):// to \(host)) — plaintext block-fetch exposes credentials")
        }
    }

    #if canImport(Darwin)
    static func makeBridge(for serverURL: URL,
                           webSocketFactory: WebSocketFactory,
                           httpClient: HTTPClient) async throws -> JSBridge {
        try await makeBridge(for: serverURL, webSocketFactory: webSocketFactory,
                             httpClient: httpClient, resourceProvider: .bundle)
    }
    #endif

    static func makeBridge(for serverURL: URL,
                           webSocketFactory: WebSocketFactory,
                           httpClient: HTTPClient,
                           resourceProvider: JSResourceProvider) async throws -> JSBridge {
        let bridge = try JSBridge(resourceProvider: resourceProvider)
        try bridge.installPlatformShims(
            serverURL: serverURL,
            webSocketFactory: webSocketFactory,
            httpClient: httpClient
        )
        try bridge.evalResource(name: "worker.bundle.min")
        try loadCryptoLibraries(bridge: bridge)
        try bridge.evalResource(name: "bootstrap")
        try loadAppConfig(bridge: bridge)
        return bridge
    }

    static func loadCryptoLibraries(bridge: JSBridge) throws {
        try bridge.evalResource(name: "nacl-fast.min")
        try bridge.eval("""
            if (!globalThis.nacl || !globalThis.nacl.secretbox) {
                throw new Error('SwiftPad: tweetnacl did not attach');
            }
            """)
    }

    static func loadAppConfig(bridge: JSBridge) throws {
        try bridge.eval("""
            globalThis.module = { exports: {} };
            globalThis.exports = globalThis.module.exports;
            """)
        try bridge.evalResource(name: "application_config")
        try bridge.eval("""
            globalThis.__sp_AppConfig =
                (globalThis.module && globalThis.module.exports) || {};
            delete globalThis.module;
            delete globalThis.exports;
            Object.freeze(globalThis.__sp_AppConfig);
            """)
    }
}

private final class FileStreamPuller: @unchecked Sendable {
    private weak var bridge: JSBridge?
    private let handle: Int
    private let maxBytes: Int?
    private var pending: [Data] = []
    private var pendingIndex = 0
    private var totalBytes = 0
    private var jsDone = false
    private var closed = false

    init(bridge: JSBridge?, handle: Int, maxBytes: Int?) {
        self.bridge = bridge
        self.handle = handle
        self.maxBytes = maxBytes
    }

    deinit { closeHandle() }

    private func closeHandle() {
        guard !closed else { return }
        closed = true
        guard let bridge = bridge else { return }
        let h = handle
        Task { _ = try? await bridge.callAsync("__swiftpad.streamFileContent_close", args: [h]) }
    }

    func next() async throws -> Data? {
        do {
            return try await pullNext()
        } catch {
            closeHandle()
            throw error
        }
    }

    private func pullNext() async throws -> Data? {
        try Task.checkCancellation()
        while true {
            if pendingIndex < pending.count {
                let chunk = pending[pendingIndex]
                pendingIndex += 1
                if pendingIndex == pending.count {
                    pending = []
                    pendingIndex = 0
                }
                if let cap = maxBytes, totalBytes + chunk.count > cap {
                    throw SwiftPadError.workerError(
                        code: "FILE_TOO_LARGE",
                        details: ["errorType": "plaintext exceeded maxBytes=\(cap) at chunk boundary \(totalBytes)+\(chunk.count)"])
                }
                totalBytes += chunk.count
                return chunk
            }
            if jsDone {
                closeHandle()
                return nil
            }
            guard let bridge = bridge else { throw SwiftPadError.bridgeClosed }
            let nextJSON: String
            do {
                nextJSON = try await bridge.callAsync("__swiftpad.streamFileContent_next", args: [handle])
            } catch {
                throw SwiftPadSession.mapBridgeError(error)
            }
            guard let nextData = nextJSON.data(using: .utf8),
                  let nextObj = try? JSONSerialization.jsonObject(with: nextData) as? [String: Any] else {
                throw SwiftPadError.protocolError("streamFileContent: non-JSON next response")
            }
            if let errCode = nextObj["error"] as? String {
                var details: [String: String]? = nil
                if let errType = nextObj["errorType"] as? String {
                    details = ["errorType": errType]
                }
                throw SwiftPadError.workerError(code: errCode, details: details)
            }
            guard let chunksB64 = nextObj["chunks"] as? [String],
                  let isDone = nextObj["done"] as? Bool else {
                throw SwiftPadError.protocolError("streamFileContent: next response missing chunks/done fields")
            }
            var batch: [Data] = []
            batch.reserveCapacity(chunksB64.count)
            for b64 in chunksB64 {
                guard let chunk = Data(base64Encoded: b64) else {
                    throw SwiftPadError.protocolError("streamFileContent: chunk not base64")
                }
                batch.append(chunk)
            }
            pending = batch
            pendingIndex = 0
            jsDone = isDone
        }
    }
}
