#if canImport(Darwin)
import SwiftPadCore
import Foundation

@_silgen_name("system")
private func libc_system(_ command: UnsafePointer<CChar>?) -> Int32

actor CLIInMemoryBlobStore: SecureBlobStore {
    private var entries: [String: Data] = [:]
    func store(key: String, bytes: Data, policy: SwiftPadCachePolicy) async throws {
        entries[key] = bytes
    }
    func fetch(key: String, policy: SwiftPadCachePolicy) async throws -> Data? {
        entries[key]
    }
    func evict(key: String) async throws {
        entries.removeValue(forKey: key)
    }
    func evictAll(prefix: String) async throws {
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }
    var entryCount: Int { entries.count }
}

final class CLIReplState: @unchecked Sendable {
    static let shared = CLIReplState()
    private let queue = DispatchQueue(label: "swiftpad.cli.repl-state")
    private var _cache: PadDocumentCache?
    private var _driveCache: DriveSnapshotCache?
    private var _serverURL: URL?
    private var _username: String?

    var cache: PadDocumentCache? {
        get { queue.sync { _cache } }
        set { queue.sync { _cache = newValue } }
    }

    var driveCache: DriveSnapshotCache? {
        get { queue.sync { _driveCache } }
        set { queue.sync { _driveCache = newValue } }
    }

    var serverURL: URL? {
        get { queue.sync { _serverURL } }
        set { queue.sync { _serverURL = newValue } }
    }

    var username: String? {
        get { queue.sync { _username } }
        set { queue.sync { _username = newValue } }
    }
}

@main
struct SwiftPadCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first else { printUsage(); exit(64) }
        let rest = Array(args.dropFirst())

        switch first {
        case "signin":
            await runSignin(args: rest)
            return
        case "signup":
            await runSignup(args: rest)
            return
        case "interactive":
            await runInteractive(args: rest)
            return
        default:
            break
        }

        guard let resolved = resolveVerb(args) else {
            printUsage(); exit(64)
        }
        let postVerb = resolved.remainingArgs
        guard postVerb.count >= 3, let url = URL(string: postVerb[2]) else {
            printUsage(); exit(64)
        }
        let user = postVerb[0]
        guard let password = resolvePassword(postVerb[1]) else { exit(64) }
        let verbArgs = Array(postVerb.dropFirst(3))
        let prefix = resolved.def.cliPrefix
        do {
            try resolved.def.validator(verbArgs)
            printSigninProgress()
            let session = try await SwiftPadSession.signIn(serverURL: url, username: user, password: password)
            defer { session.close() }
            CLIReplState.shared.username = user
            CLIReplState.shared.serverURL = url
            defer {
                CLIReplState.shared.username = nil
                CLIReplState.shared.serverURL = nil
            }
            try await resolved.def.handler(session, verbArgs)
            exit(0)
        } catch CLIError.usage(let msg) {
            FileHandle.standardError.write(Data("\(prefix) USAGE \(escapeControlChars(msg))\n".utf8))
            exit(64)
        } catch {
            let hint = totpHint(error).map { " — \($0)" } ?? ""
            print("\(prefix) FAIL \(escapeControlChars("\(error)"))\(hint)")
            exit(1)
        }
    }

    static func printUsage() {
        let usage = """
        swiftpad-cli <command> [args]

        commands:                (any <password> may be `-`: prompted hidden on a TTY, read from stdin's first line when piped)
          signin --anonymous <server-url>
          signin <username> <password> <server-url> [--totp <code>]   (TOTP accounts auto-prompt for a code on a TTY; --totp for scripts)
          signup <username> <password> <server-url>                (create the account and sign in; the instance's password minimum applies, 8 by default)
          interactive <username> <password> <server-url> [--totp <code>]   (REPL — sign in once, run many; prompts for a code if needed)
          drive <username> <password> <server-url>
          drive tree <username> <password> <server-url>           (folder hierarchy + trash + templates)
          drive cache export <username> <password> <server-url>
          usage <username> <password> <server-url>                (pinned bytes + plan limit)
          pad get <username> <password> <server-url> <channel>    (server-side metadata.ndjson contents)
          pad content <username> <password> <server-url> <channel> [--raw|--json]  (chainpad-replayed document; --raw dumps source for `code`/`slide` only; --json prints the envelope)
          pad set <username> <password> <server-url> <channel> <content-file>  (whole-document write; last-writer-wins)
          pad edit <username> <password> <server-url> <channel>  (open in $EDITOR, save on exit)
          pad watch <username> <password> <server-url> <channel> [--print-content]  (stream incoming patches; Ctrl-C to exit)
          pad chat-history <username> <password> <server-url> <channel> [count]  (pad's chat messages, oldest-first; channel = the PAD's channel)
          pad chat-watch <username> <password> <server-url> <channel>  (stream incoming chat messages; Ctrl-C to exit)
          pad chat-send <username> <password> <server-url> <channel> <text>  (send one chat message; quote multi-word text)
          pad duplicate <username> <password> <server-url> <source-channel> <new-title>  (read source content → create new → write same)
          pad create <username> <password> <server-url> <title> [type]
          pad delete <username> <password> <server-url> <channel>
          pad destroy <username> <password> <server-url> <channel>
          pad rename <username> <password> <server-url> <channel> <title>
          pad restore <username> <password> <server-url> <channel>
          pad purge-trash <username> <password> <server-url>
          pad list-deleted <username> <password> <server-url> <ch1[,ch2,...]>
          pad share-links <username> <password> <server-url> <channel>     (edit/view/present/embed URLs)
          pad set-tags <username> <password> <server-url> <channel> [<tag>...]  (whole-list write; zero tags clears all)
          pad get-tags <username> <password> <server-url> <channel>        (one tag per line; empty stdout for never-tagged)
          pad warm <username> <password> <server-url> <channel>
          pad warm-all <username> <password> <server-url>                  (warm every pad in the user's drive; best-effort)
          caches evict-all <username> <password> <server-url>
          account info <username> <password> <server-url>                  (edPublic, curvePublic, profileUrl, notifications)
          account profile <username> <password> <server-url>               (profile content: name, description, url, avatar)
          account set-description <username> <password> <server-url> <text>  (profile bio, markdown; unquoted words are joined; "" clears)
          account set-url <username> <password> <server-url> <url>         (profile link; stored opaque; exactly one arg; "" clears)
          account set-avatar <username> <password> <server-url> <path>     (png/jpg/webp/gif ≤ 500000 bytes, pre-cropped; uploads + sets)
          account remove-avatar <username> <password> <server-url>         (clears profile avatar; blob + drive entry retained)
          attr get <username> <password> <server-url> <dotted.path>        (raw-JSON settings read, e.g. general.autostore; (none) if absent)
          attr set-bool <username> <password> <server-url> <dotted.path> <true|false>
          attr set-int <username> <password> <server-url> <dotted.path> <integer>
          attr set-string <username> <password> <server-url> <dotted.path> <value>  (String rows only — see settings catalogue; "" is a value, not a delete)
          attr clear <username> <password> <server-url> <dotted.path>      (deletes the key; absent ≠ "")
          team list <username> <password> <server-url>                     (all teams; id, owner, offline, error, name)
          team info <username> <password> <server-url> <teamId>            (name, topic, avatar, offline)
          team roster <username> <password> <server-url> <teamId>          (members + pending invite placeholders)
          team drive <username> <password> <server-url> <teamId>           (team drive flat listing; DriveEntry shape)
          team usage <username> <password> <server-url> <teamId>           (pinned bytes + limit + plan)
          team limit <username> <password> <server-url> <teamId>           (pin quota limit + plan + note; unknown teamId hangs ~30s — upstream guard gap)
          team create <username> <password> <server-url> <name>            (dual cap gate; 15s timeout — on timeout re-run team list)
          team leave <username> <password> <server-url> <teamId>           (self-leave; NO sole-owner guard upstream — check roster first)
          team delete <username> <password> <server-url> <teamId>          (owner-only; KNOWN: times out ~30s headless but LANDS — re-run team list)
          team rename <username> <password> <server-url> <teamId> <name>   (partial metadata update; topic/avatar API-only)
          team invite <username> <password> <server-url> <teamId> <curvePublic>  (direct invite; contact resolved from contacts list)
          team kick <username> <password> <server-url> <teamId> <curvePublic>    (admin/owner remove; member notified via mailbox)
          team link-create <username> <password> <server-url> <teamId> <name> [viewer|member] [linkPassword]  (single-use invite URL; message API-only)
          team link-preview <username> <password> <server-url> <url>       (preview without joining; works pre-auth via the API)
          team link-accept <username> <password> <server-url> <url> [linkPassword]  (join via invite link)
          contacts list <username> <password> <server-url>                 (friends + pending; curvePublic-keyed)
          contacts requests <username> <password> <server-url>             (incoming friend requests; eventually consistent)
          contacts request <username> <password> <server-url> <curvePublic> <notificationsChannel>  (send a friend request)
          contacts cancel <username> <password> <server-url> <curvePublic> (cancel an outgoing request)
          contacts accept <username> <password> <server-url> <curvePublic> (accept an incoming request)
          contacts decline <username> <password> <server-url> <curvePublic> (decline an incoming request)
          contacts remove <username> <password> <server-url> <curvePublic>  (unfriend an established contact)
          notif list <username> <password> <server-url>                    (undismissed mailbox backlog, all boxes; eventually consistent)
          notif watch <username> <password> <server-url>                   (stream mailbox notifications; Ctrl-C to exit)
          notif ack <username> <password> <server-url> <box> <hash>        (dismiss one notification; box+hash from `notif list`)
          notif history <username> <password> <server-url> <box> [count] [before]  (already-dismissed notifications, oldest-first)
          dm history <username> <password> <server-url> <curvePublic> [count]  (1-1 chat with an existing contact, oldest-first)
          dm watch <username> <password> <server-url> <curvePublic>        (stream incoming DMs; Ctrl-C to exit)
          dm send <username> <password> <server-url> <curvePublic> <text>  (send one DM; POLLUTES permanent history — no per-message delete)
          file get <username> <password> <server-url> <channel> <output-path> [--force]
          file up <username> <password> <server-url> <local-path> [--title <title>] [--mime <type>]
          calendar list <username> <password> <server-url>                 (personal + team calendars; team ones read-only)
          calendar events <username> <password> <server-url> <calendarId>  (raw events; recurring shown once, flagged)
          calendar create <username> <password> <server-url> <title> [#rrggbb]  (personal store; quote multi-word titles; default color #3771fb)
          calendar rename <username> <password> <server-url> <calendarId> <title>
          calendar recolor <username> <password> <server-url> <calendarId> <#rrggbb>
          calendar delete <username> <password> <server-url> <calendarId>  (personal only; unpins the channel)
          event create <username> <password> <server-url> <calendarId> <title> <start> [<end>]
                                            (start/end "YYYY-MM-DDTHH:MM" local, or "YYYY-MM-DD" = all-day;
                                             default end: start+1h timed, same-day all-day; quote the title)
          event set <username> <password> <server-url> <calendarId> <eventId> <field> <value>
                                            (field: title|location|body|start|end|reminders; reminders "10,60" or "none";
                                             recurring events refused — edit those in the web client)
          event delete <username> <password> <server-url> <calendarId> <eventId>  (whole events; no occurrence ids)

        """
        FileHandle.standardError.write(Data(usage.utf8))
    }


    typealias VerbValidator = @Sendable ([String]) throws -> Void
    typealias VerbHandler = @Sendable (SwiftPadSession, [String]) async throws -> Void

    struct VerbDef: Sendable {
        let name: String
        let validator: VerbValidator
        let handler: VerbHandler

        var cliPrefix: String {
            name.uppercased().replacingOccurrences(of: " ", with: "-")
        }
    }

    static let verbRegistry: [String: VerbDef] = [
        "drive":            VerbDef(name: "drive",            validator: noopValidator, handler: handleDrive),
        "drive tree":       VerbDef(name: "drive tree",       validator: noopValidator, handler: handleDriveTree),
        "usage":            VerbDef(name: "usage",            validator: noopValidator, handler: handleUsage),
        "pad get":          VerbDef(name: "pad get",          validator: validateChannelFirst("pad get"),
                                    handler: handlePadGet),
        "pad content":      VerbDef(name: "pad content",      validator: validateChannelFirst("pad content"),
                                    handler: handlePadContent),
        "pad set":          VerbDef(name: "pad set",          validator: validatePadSet,
                                    handler: handlePadSet),
        "pad duplicate":    VerbDef(name: "pad duplicate",    validator: validatePadDuplicate,
                                    handler: handlePadDuplicate),
        "pad edit":         VerbDef(name: "pad edit",         validator: validateChannelFirst("pad edit"),
                                    handler: handlePadEdit),
        "pad watch":        VerbDef(name: "pad watch",        validator: validateChannelFirst("pad watch"),
                                    handler: handlePadWatch),
        "pad chat-history": VerbDef(name: "pad chat-history", validator: validateChannelFirst("pad chat-history"),
                                    handler: handlePadChatHistory),
        "pad chat-watch":   VerbDef(name: "pad chat-watch",   validator: validateChannelFirst("pad chat-watch"),
                                    handler: handlePadChatWatch),
        "pad chat-send":    VerbDef(name: "pad chat-send",    validator: validatePadChatSend,
                                    handler: handlePadChatSend),
        "pad create":       VerbDef(name: "pad create",       validator: validatePadCreate,  handler: handlePadCreate),
        "pad delete":       VerbDef(name: "pad delete",       validator: validateAnyChannelFirst("pad delete"),
                                    handler: handlePadDelete),
        "pad destroy":      VerbDef(name: "pad destroy",      validator: validateAnyChannelFirst("pad destroy"),
                                    handler: handlePadDestroy),
        "pad rename":       VerbDef(name: "pad rename",       validator: validatePadRename,
                                    handler: handlePadRename),
        "pad purge-trash":  VerbDef(name: "pad purge-trash",  validator: noopValidator, handler: handlePadPurgeTrash),
        "pad restore":      VerbDef(name: "pad restore",      validator: validateChannelFirst("pad restore"),
                                    handler: handlePadRestore),
        "pad list-deleted": VerbDef(name: "pad list-deleted", validator: validateListDeleted,
                                    handler: handlePadListDeleted),
        "pad share-links":  VerbDef(name: "pad share-links",  validator: validateChannelFirst("pad share-links"),
                                    handler: handlePadShareLinks),
        "pad set-tags":     VerbDef(name: "pad set-tags",     validator: validatePadSetTags,
                                    handler: handlePadSetTags),
        "pad get-tags":     VerbDef(name: "pad get-tags",     validator: validateChannelFirst("pad get-tags"),
                                    handler: handlePadGetTags),
        "pad warm":         VerbDef(name: "pad warm",         validator: validateChannelFirst("pad warm"),
                                    handler: handlePadWarm),
        "pad warm-all":     VerbDef(name: "pad warm-all",     validator: noopValidator, handler: handlePadWarmAll),
        "caches evict-all":   VerbDef(name: "caches evict-all",   validator: noopValidator, handler: handleCachesEvictAll),
        "drive cache export": VerbDef(name: "drive cache export", validator: noopValidator, handler: handleDriveCacheExport),
        "account info":       VerbDef(name: "account info",       validator: noopValidator, handler: handleAccountInfo),
        "account profile":    VerbDef(name: "account profile",    validator: noopValidator, handler: handleAccountProfile),
        "account set-description": VerbDef(name: "account set-description",
                                           validator: validateValueArgPresent("account set-description", "text"),
                                           handler: handleAccountSetDescription),
        "account set-url":    VerbDef(name: "account set-url",
                                      validator: validateProfileUrlArg,
                                      handler: handleAccountSetUrl),
        "account set-avatar": VerbDef(name: "account set-avatar",
                                      validator: validateAvatarPath,
                                      handler: handleAccountSetAvatar),
        "account remove-avatar": VerbDef(name: "account remove-avatar",
                                         validator: noopValidator,
                                         handler: handleAccountRemoveAvatar),
        "attr get":        VerbDef(name: "attr get",        validator: validateAttrPathOnly("attr get"),
                                   handler: handleAttrGet),
        "attr set-bool":   VerbDef(name: "attr set-bool",   validator: validateAttrSetBool,
                                   handler: handleAttrSetBool),
        "attr set-int":    VerbDef(name: "attr set-int",    validator: validateAttrSetInt,
                                   handler: handleAttrSetInt),
        "attr set-string": VerbDef(name: "attr set-string", validator: validateAttrSetString,
                                   handler: handleAttrSetString),
        "attr clear":      VerbDef(name: "attr clear",      validator: validateAttrPathOnly("attr clear"),
                                   handler: handleAttrClear),
        "team list":          VerbDef(name: "team list",          validator: noopValidator, handler: handleTeamList),
        "team info":          VerbDef(name: "team info",          validator: validateTeamIdFirst("team info"), handler: handleTeamInfo),
        "team roster":        VerbDef(name: "team roster",        validator: validateTeamIdFirst("team roster"), handler: handleTeamRoster),
        "team create":        VerbDef(name: "team create",        validator: validateTeamCreate, handler: handleTeamCreate),
        "team leave":         VerbDef(name: "team leave",         validator: validateTeamIdFirst("team leave"), handler: handleTeamLeave),
        "team delete":        VerbDef(name: "team delete",        validator: validateTeamIdFirst("team delete"), handler: handleTeamDelete),
        "team drive":         VerbDef(name: "team drive",         validator: validateTeamIdFirst("team drive"), handler: handleTeamDrive),
        "team usage":         VerbDef(name: "team usage",         validator: validateTeamIdFirst("team usage"), handler: handleTeamUsage),
        "team limit":         VerbDef(name: "team limit",         validator: validateTeamIdFirst("team limit"), handler: handleTeamLimit),
        "team rename":        VerbDef(name: "team rename",        validator: validateTeamRename, handler: handleTeamRename),
        "team invite":        VerbDef(name: "team invite",        validator: validateTeamCurveSecond("team invite"), handler: handleTeamInvite),
        "team kick":          VerbDef(name: "team kick",          validator: validateTeamCurveSecond("team kick"), handler: handleTeamKick),
        "team link-create":   VerbDef(name: "team link-create",   validator: validateTeamLinkCreate, handler: handleTeamLinkCreate),
        "team link-preview":  VerbDef(name: "team link-preview",  validator: validateInviteURLFirst("team link-preview"), handler: handleTeamLinkPreview),
        "team link-accept":   VerbDef(name: "team link-accept",   validator: validateInviteURLFirst("team link-accept"), handler: handleTeamLinkAccept),
        "contacts list":      VerbDef(name: "contacts list",      validator: noopValidator, handler: handleContactsList),
        "contacts requests":  VerbDef(name: "contacts requests",  validator: noopValidator, handler: handleContactsRequests),
        "contacts request":   VerbDef(name: "contacts request",   validator: validateContactRequestArgs("contacts request"), handler: handleContactsRequest),
        "contacts cancel":    VerbDef(name: "contacts cancel",    validator: validateDMCurveFirst("contacts cancel"), handler: handleContactsCancel),
        "contacts accept":    VerbDef(name: "contacts accept",    validator: validateDMCurveFirst("contacts accept"), handler: handleContactsAccept),
        "contacts decline":   VerbDef(name: "contacts decline",   validator: validateDMCurveFirst("contacts decline"), handler: handleContactsDecline),
        "contacts remove":    VerbDef(name: "contacts remove",    validator: validateDMCurveFirst("contacts remove"), handler: handleContactsRemove),
        "notif list":         VerbDef(name: "notif list",         validator: noopValidator, handler: handleNotifList),
        "notif watch":        VerbDef(name: "notif watch",        validator: noopValidator, handler: handleNotifWatch),
        "notif ack":          VerbDef(name: "notif ack",          validator: validateNotifAck, handler: handleNotifAck),
        "notif history":      VerbDef(name: "notif history",      validator: validateNotifHistory, handler: handleNotifHistory),
        "dm history":         VerbDef(name: "dm history",         validator: validateDMCurveFirst("dm history"), handler: handleDMHistory),
        "dm watch":           VerbDef(name: "dm watch",           validator: validateDMCurveFirst("dm watch"), handler: handleDMWatch),
        "dm send":            VerbDef(name: "dm send",            validator: validateDMSend, handler: handleDMSend),
        "file get":         VerbDef(name: "file get",         validator: validateFileGet,
                                    handler: handleFileGet),
        "file up":          VerbDef(name: "file up",          validator: validateFileUp,
                                    handler: handleFileUp),
        "calendar list":    VerbDef(name: "calendar list",    validator: noopValidator, handler: handleCalendarList),
        "calendar events":  VerbDef(name: "calendar events",  validator: validateChannelFirst("calendar events"),
                                    handler: handleCalendarEvents),
        "calendar create":  VerbDef(name: "calendar create",  validator: validateCalendarCreate,
                                    handler: handleCalendarCreate),
        "calendar rename":  VerbDef(name: "calendar rename",  validator: validateCalendarRename,
                                    handler: handleCalendarRename),
        "calendar recolor": VerbDef(name: "calendar recolor", validator: validateCalendarRecolor,
                                    handler: handleCalendarRecolor),
        "calendar delete":  VerbDef(name: "calendar delete",  validator: validateChannelFirst("calendar delete"),
                                    handler: handleCalendarDelete),
        "event create":     VerbDef(name: "event create",     validator: validateEventCreate,
                                    handler: handleEventCreate),
        "event set":        VerbDef(name: "event set",        validator: validateEventSet,
                                    handler: handleEventSet),
        "event delete":     VerbDef(name: "event delete",     validator: validateEventDelete,
                                    handler: handleEventDelete),
    ]

    struct ResolvedVerb {
        let def: VerbDef
        let remainingArgs: [String]
    }

    static func resolveVerb(_ args: [String]) -> ResolvedVerb? {
        guard !args.isEmpty else { return nil }
        if args.count >= 3 {
            let threeKey = "\(args[0]) \(args[1]) \(args[2])"
            if let def = verbRegistry[threeKey] {
                return ResolvedVerb(def: def, remainingArgs: Array(args.dropFirst(3)))
            }
        }
        if args.count >= 2 {
            let twoKey = "\(args[0]) \(args[1])"
            if let def = verbRegistry[twoKey] {
                return ResolvedVerb(def: def, remainingArgs: Array(args.dropFirst(2)))
            }
        }
        if let def = verbRegistry[args[0]] {
            return ResolvedVerb(def: def, remainingArgs: Array(args.dropFirst()))
        }
        return nil
    }


    static let noopValidator: VerbValidator = { _ in }

    static func validateChannelFirst(_ verb: String) -> VerbValidator {
        return { args in
            guard let c = args.first else {
                throw CLIError.usage("\(verb): missing <channel>")
            }
            try requireChannelShape(c, verb: verb)
        }
    }

    static func validateTeamIdFirst(_ verb: String) -> VerbValidator {
        return { args in
            guard let id = args.first, !id.isEmpty else {
                throw CLIError.usage("\(verb): missing <teamId>")
            }
            guard id.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw CLIError.usage("\(verb): teamId must be a decimal-digit string; got '\(id)'")
            }
        }
    }

    static let validatePadCreate: VerbValidator = { args in
        guard let title = args.first, !title.isEmpty else {
            throw CLIError.usage("pad create: missing <title>")
        }
    }

    static let validatePadRename: VerbValidator = { args in
        guard let c = args.first else {
            throw CLIError.usage("pad rename: missing <channel>")
        }
        try requireChannelShape(c, verb: "pad rename")
        guard args.count >= 2, !args[1].isEmpty else {
            throw CLIError.usage("pad rename: missing <title>")
        }
    }

    static let validatePadChatSend: VerbValidator = { args in
        guard let c = args.first else {
            throw CLIError.usage("pad chat-send: missing <channel>")
        }
        try requireChannelShape(c, verb: "pad chat-send")
        guard args.count >= 2, !args[1].isEmpty else {
            throw CLIError.usage("pad chat-send: missing <text> (quote multi-word messages)")
        }
    }

    static let validatePadSet: VerbValidator = { args in
        guard let c = args.first else {
            throw CLIError.usage("pad set: missing <channel>")
        }
        try requireChannelShape(c, verb: "pad set")
        guard args.count >= 2 else {
            throw CLIError.usage("pad set: missing <content-file>")
        }
        let path = args[1]
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw CLIError.usage("pad set: file not found at '\(path)'")
        }
        guard fm.isReadableFile(atPath: path) else {
            throw CLIError.usage("pad set: file not readable at '\(path)'")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            throw CLIError.usage("pad set: file empty or unreadable at '\(path)'")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw CLIError.usage("pad set: file at '\(path)' is not valid UTF-8")
        }
    }

    static let validatePadSetTags: VerbValidator = { args in
        guard let c = args.first else {
            throw CLIError.usage("pad set-tags: missing <channel>")
        }
        try requireChannelShape(c, verb: "pad set-tags")
        for (i, tag) in args.dropFirst().enumerated() {
            if tag.isEmpty {
                throw CLIError.usage("pad set-tags: tag values must be non-empty (arg #\(i + 1) was empty)")
            }
        }
    }

    static let validatePadDuplicate: VerbValidator = { args in
        guard let c = args.first else {
            throw CLIError.usage("pad duplicate: missing <source-channel>")
        }
        try requireChannelShape(c, verb: "pad duplicate")
        guard args.count >= 2, !args[1].isEmpty else {
            throw CLIError.usage("pad duplicate: missing <new-title>")
        }
    }

    static let validateListDeleted: VerbValidator = { args in
        guard let listArg = args.first else {
            throw CLIError.usage("pad list-deleted: missing <ch1[,ch2,...]>")
        }
        let cs = listArg.split(separator: ",").map(String.init)
        guard cs.count <= 100 else {
            throw CLIError.usage("pad list-deleted: max 100 candidates per call (use Swift API directly for batch)")
        }
        for c in cs { try requireChannelShape(c, verb: "pad list-deleted") }
    }

    static func requireChannelShape(_ s: String, verb: String) throws {
        guard s.count == 32, s.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
            throw CLIError.usage("\(verb): channel '\(s)' must be 32 lowercase-hex chars")
        }
    }

    static func validateAnyChannelFirst(_ verb: String) -> VerbValidator {
        return { args in
            guard let c = args.first else {
                throw CLIError.usage("\(verb): missing <channel>")
            }
            guard c.count == 32 || c.count == 48,
                  c.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
                throw CLIError.usage("\(verb): channel '\(c)' must be 32 (pad) or 48 (file) lowercase-hex chars")
            }
        }
    }

    static func requireFileChannelShape(_ s: String, verb: String) throws {
        guard s.count == 48, s.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
            throw CLIError.usage("\(verb): channel '\(s)' must be 48 lowercase-hex chars (file-type)")
        }
    }

    static let validateFileGet: VerbValidator = { args in
        guard let c = args.first else {
            throw CLIError.usage("file get: missing <channel>")
        }
        try requireFileChannelShape(c, verb: "file get")
        guard args.count >= 2 else {
            throw CLIError.usage("file get: missing <output-path>")
        }
        let path = args[1]
        let force = args.count >= 3 && args[2] == "--force"
        let fm = FileManager.default
        if fm.fileExists(atPath: path) && !force {
            throw CLIError.usage("file get: output path '\(path)' already exists; pass --force to overwrite")
        }
        let parent = (path as NSString).deletingLastPathComponent
        let parentToCheck = parent.isEmpty ? "." : parent
        guard fm.isWritableFile(atPath: parentToCheck) else {
            throw CLIError.usage("file get: parent directory '\(parentToCheck)' is not writeable")
        }
    }

    static let validateFileUp: VerbValidator = { args in
        guard let path = args.first else {
            throw CLIError.usage("file up: missing <local-path>")
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw CLIError.usage("file up: input path '\(path)' does not exist")
        }
        if isDir.boolValue {
            throw CLIError.usage("file up: input path '\(path)' is a directory; pass a file")
        }
        guard fm.isReadableFile(atPath: path) else {
            throw CLIError.usage("file up: input path '\(path)' is not readable")
        }
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--title":
                guard i + 1 < args.count else {
                    throw CLIError.usage("file up: --title requires a value")
                }
                i += 2
            case "--mime":
                guard i + 1 < args.count else {
                    throw CLIError.usage("file up: --mime requires a value")
                }
                i += 2
            default:
                throw CLIError.usage("file up: unknown flag '\(args[i])'")
            }
        }
    }

    static func guessMimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":  return "application/pdf"
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":  return "image/gif"
        case "webp": return "image/webp"
        case "svg":  return "image/svg+xml"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "json": return "application/json"
        case "zip":  return "application/zip"
        case "mp4":  return "video/mp4"
        case "webm": return "video/webm"
        case "mp3":  return "audio/mpeg"
        case "wav":  return "audio/wav"
        case "html", "htm": return "text/html; charset=utf-8"
        case "css":  return "text/css; charset=utf-8"
        case "js":   return "application/javascript"
        default:     return "application/octet-stream"
        }
    }


    static func totpHint(_ error: Error) -> String? {
        guard case SwiftPadError.authFailed(let reason) = error else { return nil }
        switch reason {
        case .totpRequired:
            return "account is TOTP-protected — pass --totp <6-digit code> (signin/interactive only; other verbs: use interactive)"
        case .totpInvalid:
            return "code rejected (malformed or wrong — NOT a password problem); generate a fresh code and retry"
        case .totpValidateFailed:
            return "server fault during TOTP validation (no cache touched); retry with a fresh code — code-less if the detail says NO_MFA_CONFIGURED"
        case .blockNotFound, .blockDecryptFailed, .blockFetchFailed, .passwordRequired:
            return nil
        }
    }

    static func extractTotpFlag(_ args: [String]) -> (rest: [String], code: String?)? {
        guard let idx = args.firstIndex(of: "--totp") else { return (args, nil) }
        guard idx + 1 < args.count else { return nil }
        var rest = args
        let code = rest[idx + 1]
        rest.removeSubrange(idx...(idx + 1))
        guard !rest.contains("--totp") else { return nil }
        return (rest, code)
    }

    static func printSigninProgress() {
        FileHandle.standardError.write(Data("signing in…\n".utf8))
    }

    static func readHiddenLine(prompt: String) -> String? {
        FileHandle.standardError.write(Data(prompt.utf8))
        guard isatty(STDIN_FILENO) != 0 else {
            return readLine(strippingNewline: true)
        }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return readLine(strippingNewline: true)
        }
        var muted = original
        muted.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &muted)
        defer {
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        return readLine(strippingNewline: true)
    }

    static func resolvePassword(_ raw: String) -> String? {
        guard raw == "-" else { return raw }
        guard let pw = readHiddenLine(prompt: "password (hidden): "), !pw.isEmpty else {
            FileHandle.standardError.write(Data("empty password\n".utf8))
            return nil
        }
        return pw
    }

    static func signInPromptingForTotp(serverURL: URL, username: String,
                                       password: String, totpCode: String?)
        async throws -> SwiftPadSession {
        do {
            printSigninProgress()
            return try await SwiftPadSession.signIn(serverURL: serverURL, username: username,
                                                    password: password, totpCode: totpCode)
        } catch SwiftPadError.authFailed(reason: .totpRequired) where totpCode == nil && isatty(STDIN_FILENO) != 0 {
            guard let line = readHiddenLine(prompt: "account is TOTP-protected. TOTP code (hidden): "),
                  !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw SwiftPadError.authFailed(reason: .totpRequired)
            }
            let code = line.trimmingCharacters(in: .whitespaces)
            return try await SwiftPadSession.signIn(serverURL: serverURL, username: username,
                                                    password: password, totpCode: code)
        }
    }

    static func runSignin(args rawArgs: [String]) async {
        guard let (args, totpCode) = extractTotpFlag(rawArgs) else {
            printUsage(); exit(64)
        }
        if args.first == "--anonymous" {
            guard totpCode == nil else { printUsage(); exit(64) }
            guard args.count >= 2, let url = URL(string: args[1]) else {
                printUsage(); exit(64)
            }
            do {
                let session = try await SwiftPadSession.anonymous(serverURL: url)
                print("ANONYMOUS OK server=\(session.serverURL.absoluteString)")
                exit(0)
            } catch {
                print("ANONYMOUS FAIL \(escapeControlChars("\(error)"))")
                exit(1)
            }
        }
        guard args.count >= 3, let url = URL(string: args[2]) else {
            printUsage(); exit(64)
        }
        let username = args[0]
        guard let password = resolvePassword(args[1]) else { exit(64) }
        do {
            let session = try await signInPromptingForTotp(serverURL: url, username: username,
                                                           password: password, totpCode: totpCode)
            print("SIGNIN OK user=\(username) server=\(session.serverURL.absoluteString)")
            exit(0)
        } catch {
            let hint = totpHint(error).map { " — \($0)" } ?? ""
            print("SIGNIN FAIL \(escapeControlChars("\(error)"))\(hint)")
            exit(1)
        }
    }

    static func runSignup(args rawArgs: [String]) async {
        guard let (args, totpCode) = extractTotpFlag(rawArgs), totpCode == nil else {
            printUsage(); exit(64)
        }
        guard args.count >= 3, let url = URL(string: args[2]) else {
            printUsage(); exit(64)
        }
        let username = args[0]
        guard let password = resolvePassword(args[1]) else { exit(64) }
        do {
            FileHandle.standardError.write(Data("creating the account…\n".utf8))
            let session = try await SwiftPadSession.signUp(serverURL: url, username: username, password: password)
            let canonical = escapeControlChars(session.username ?? "")
            session.close()
            print("SIGNUP OK user=\(canonical) server=\(session.serverURL.absoluteString)")
            exit(0)
        } catch {
            print("SIGNUP FAIL \(escapeControlChars("\(error)"))")
            exit(1)
        }
    }

    static func runInteractive(args rawArgs: [String]) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let (args, totpFlagCode) = extractTotpFlag(rawArgs) else {
            printUsage(); exit(64)
        }
        guard args.count >= 3, let url = URL(string: args[2]) else {
            printUsage(); exit(64)
        }
        let user = args[0]
        guard let resolvedPassword = resolvePassword(args[1]) else { exit(64) }
        var password = resolvedPassword

        let session: SwiftPadSession
        do {
            session = try await signInPromptingForTotp(serverURL: url, username: user,
                                                       password: password, totpCode: totpFlagCode)
        } catch {
            let hint = totpHint(error).map { " — \($0)" } ?? ""
            print("INTERACTIVE FAIL signin failed: \(escapeControlChars("\(error)"))\(hint)")
            exit(1)
        }
        password = ""
        defer { session.close() }

        let replBackend = CLIInMemoryBlobStore()
        CLIReplState.shared.cache = PadDocumentCache(backend: replBackend, policy: .biometricBound)
        defer { CLIReplState.shared.cache = nil }

        let driveBackend = CLIInMemoryBlobStore()
        CLIReplState.shared.driveCache = DriveSnapshotCache(backend: driveBackend, policy: .biometricBound)
        CLIReplState.shared.serverURL = url
        CLIReplState.shared.username = user
        defer {
            CLIReplState.shared.driveCache = nil
            CLIReplState.shared.serverURL = nil
            CLIReplState.shared.username = nil
        }

        printREPLBanner(user: user, server: url.absoluteString)

        var stale = false

        while true {
            FileHandle.standardError.write(Data("swiftpad> ".utf8))
            guard let line = readLine(strippingNewline: true) else {
                FileHandle.standardError.write(Data("\nBYE\n".utf8))
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let lower = trimmed.lowercased()
            if lower == "exit" || lower == "quit" || lower == "q" {
                FileHandle.standardError.write(Data("BYE\n".utf8))
                break
            }
            if lower == "help" || lower == "?" {
                printREPLHelp()
                continue
            }

            if stale {
                FileHandle.standardError.write(Data("BRIDGE STALE — type 'exit' to reconnect\n".utf8))
                continue
            }

            let tokens: [String]
            do {
                tokens = try tokenize(trimmed)
            } catch {
                print("PARSE FAIL \(escapeControlChars("\(error)"))")
                continue
            }

            await runREPLVerb(session: session, tokens: tokens, stale: &stale)
        }
    }

    static func runREPLVerb(session: SwiftPadSession, tokens: [String], stale: inout Bool) async {
        guard let resolved = resolveVerb(tokens) else {
            print("UNKNOWN \(tokens.joined(separator: " ")) — type 'help' for commands")
            return
        }
        let verbArgs = resolved.remainingArgs
        let prefix = resolved.def.cliPrefix
        do {
            try resolved.def.validator(verbArgs)
            try await resolved.def.handler(session, verbArgs)
        } catch CLIError.usage(let msg) {
            FileHandle.standardError.write(Data("\(prefix) USAGE \(escapeControlChars(msg))\n".utf8))
        } catch {
            if isBridgeStaleError(error) {
                stale = true
                print("\(prefix) FAIL \(escapeControlChars("\(error)"))")
                FileHandle.standardError.write(Data("BRIDGE STALE — type 'exit' to reconnect\n".utf8))
            } else {
                print("\(prefix) FAIL \(escapeControlChars("\(error)"))")
            }
        }
    }

    static func isBridgeStaleError(_ error: Error) -> Bool {
        switch error {
        case SwiftPadError.bridgeClosed, SwiftPadError.timeout,
             JSBridgeError.bridgeClosed, JSBridgeError.callTimeout:
            return true
        default:
            return false
        }
    }

    static func printREPLBanner(user: String, server: String) {
        let banner = """
        SwiftPad interactive — user=\(user) server=\(server)
        Type 'help' for commands. 'exit' / 'quit' / 'q' / Ctrl-D to leave.
        Ctrl-C terminates the process (phase-1 simplification).
        See core/CLI.md for the full surface reference.

        """
        FileHandle.standardError.write(Data(banner.utf8))
    }

    static func printREPLHelp() {
        let help = """
        REPL commands (no <user> <pass> <server> prefix needed; signed in already):
          drive
          drive tree
          drive cache export — captureDriveSnapshot JSON to stdout (diagnostic)
          usage
          pad get <channel>
          pad content <channel> [--raw|--json]
          pad set <channel> <content-file>
          pad edit <channel>
          pad watch <channel> [--print-content]
          pad chat-history <channel> [count]
          pad chat-watch <channel>
          pad chat-send <channel> "<text>"
          pad duplicate <source-channel> <new-title>
          pad create <title> [type]
          pad delete <channel>
          pad destroy <channel>
          pad rename <channel> "<title>"
          pad purge-trash
          pad restore <channel>
          pad list-deleted <ch1[,ch2,...]>
          pad share-links <channel>
          pad set-tags <channel> [<tag>...]   — whole-list write; zero tags clears
          pad get-tags <channel>              — one tag per line
          pad warm <channel> — exercise cache-aware getPadContent (throwaway cache; SHA-256 envelope)
          pad warm-all                        — warm every pad in your drive; best-effort
          caches evict-all — flush the pad + drive-snapshot caches (logout-style)
          account info
          account profile
          account set-description <text>      — profile bio (markdown; words joined; "" clears)
          account set-url <url>               — profile link (one arg; "" clears)
          account set-avatar <path>           — upload + set avatar (png/jpg/webp/gif ≤ 500000 B)
          account remove-avatar               — clear avatar (blob retained)
          attr get <dotted.path>              — raw-JSON settings read ((none) if absent)
          attr set-bool <dotted.path> <true|false>
          attr set-int <dotted.path> <integer>
          attr set-string <dotted.path> <value> — String rows only; "" is a value
          attr clear <dotted.path>            — deletes the key (absent ≠ "")
          team list
          team info <teamId>
          team roster <teamId>
          team drive <teamId>
          team usage <teamId>
          team limit <teamId>
          team create <name>
          team leave <teamId>                 — self-leave; no sole-owner guard upstream
          team delete <teamId>                — owner-only hard delete
          team rename <teamId> <name>
          team invite <teamId> <curvePublic>  — from contacts list
          team kick <teamId> <curvePublic>
          team link-create <teamId> <name> [viewer|member] [password] — single-use invite URL
          team link-preview <url>             — preview without joining (message API-only on create)
          team link-accept <url> [password]
          contacts list
          contacts requests                   — incoming friend requests (eventually consistent; short poll)
          contacts request <curvePublic> <notificationsChannel> — send a friend request
          contacts cancel <curvePublic>       — cancel an outgoing request
          contacts accept <curvePublic>       — accept an incoming request (resolves from `contacts requests`)
          contacts decline <curvePublic>      — decline an incoming request
          contacts remove <curvePublic>       — unfriend an established contact
          notif list                          — undismissed mailbox backlog (all boxes; eventually consistent)
          notif watch                         — stream mailbox notifications; Ctrl-C to exit
          notif ack <box> <hash>              — dismiss one notification (values from `notif list`)
          notif history <box> [count] [before] — already-dismissed notifications, oldest-first (default 20)
          dm history <curvePublic> [count]    — 1-1 chat with an existing contact, oldest-first
          dm watch <curvePublic>              — stream incoming DMs; Ctrl-C to exit
          dm send <curvePublic> "<text>"      — POLLUTES permanent history; no per-message delete
          file get <channel> <output-path> [--force] — streaming file-blob fetch (channel is 48-hex)
          file up <local-path> [--title <title>] [--mime <type>] — encrypt + chunked upload (MIME guessed from extension)
          calendar list                       — personal + team calendars (team ones read-only)
          calendar events <calendarId>        — raw events; recurring shown once, flagged
          calendar create "<title>" [#rrggbb] — personal store (default color #3771fb)
          calendar rename <calendarId> <title>
          calendar recolor <calendarId> <#rrggbb>
          calendar delete <calendarId>        — personal only; unpins the channel
          event create <calendarId> "<title>" <start> [<end>] — YYYY-MM-DDTHH:MM local, or YYYY-MM-DD = all-day
          event set <calendarId> <eventId> <field> <value> — title|location|body|start|end|reminders ("10,60"|"none")
          event delete <calendarId> <eventId> — whole events; recurring edits are web-client-only

        Other:
          help / ?          — this list
          exit / quit / q   — close session and leave (also Ctrl-D)

        Output: <VERB> OK key=value (success) | <VERB> FAIL <error>
        Trace lines go to stderr; command output goes to stdout.

        """
        FileHandle.standardError.write(Data(help.utf8))
    }

    static func tokenize(_ s: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var sawTokenChar = false

        for ch in s {
            if inQuote {
                if ch == "\\" {
                    throw CLIError.usage("escaped chars inside quoted strings not supported (deferred to phase-2)")
                }
                if ch == "\"" {
                    inQuote = false
                    continue
                }
                current.append(ch)
            } else {
                if ch == "\"" {
                    inQuote = true
                    sawTokenChar = true
                    continue
                }
                if ch == " " || ch == "\t" {
                    if sawTokenChar {
                        tokens.append(current)
                        current = ""
                        sawTokenChar = false
                    }
                    continue
                }
                current.append(ch)
                sawTokenChar = true
            }
        }
        if inQuote { throw CLIError.usage("unterminated quote") }
        if sawTokenChar { tokens.append(current) }
        return tokens
    }


    static let handleDrive: VerbHandler = { session, _ in
        let entries = try await session.getDrive()
        print("DRIVE \(entries.count) entries")
        for e in entries {
            print(driveEntryLine(e))
        }
    }

    static func driveEntryLine(_ e: DriveEntry) -> String {
        "  id=\(quotedField(e.id)) channel=\(quotedField(e.channel))"
            + " href=\(quotedField(e.href)) title=\(escapeControlChars(e.title))"
    }

    static func driveTreeEntryLine(_ e: DriveEntry, indent: String) -> String {
        "\(indent)channel=\(quotedField(e.channel)) title=\(escapeControlChars(e.title))"
    }

    static let handleDriveTree: VerbHandler = { session, _ in
        let tree = try await session.getDriveTree()
        print("DRIVE-TREE OK")
        printFolder(tree.root, indent: "  ")
        if !tree.templates.isEmpty {
            print("  templates/")
            for e in tree.templates {
                print(driveTreeEntryLine(e, indent: "    "))
            }
        }
        if !tree.trash.isEmpty {
            print("  trash/")
            for slot in tree.trash {
                print("    \(quotedField(slot.name))/")
                for e in slot.entries {
                    print(driveTreeEntryLine(e, indent: "      "))
                }
            }
        }
    }

    static func printFolder(_ folder: DriveFolder, indent: String) {
        print("\(indent)\(folder.name.isEmpty ? "root" : quotedField(folder.name))/")
        for e in folder.entries {
            print(driveTreeEntryLine(e, indent: indent + "  "))
        }
        for sub in folder.folders {
            printFolder(sub, indent: indent + "  ")
        }
    }

    static let handleUsage: VerbHandler = { session, _ in
        let usage = try await session.getPinnedUsage()
        let limit = try await session.getPinLimit()
        print(limitLine("USAGE bytes=\(usage.bytes)", limit))
    }

    static func limitLine(_ prefix: String, _ limit: PinLimit) -> String {
        "\(prefix) limit=\(limit.limit) plan=\(quotedField(limit.plan))"
            + " note=\(trailingField(limit.note.isEmpty ? nil : limit.note))"
    }

    static let handlePadGet: VerbHandler = { session, args in
        let channel = args[0]
        let pad = try await session.getPadMetadata(channel: channel)
        print("PAD-GET OK channel=\(pad.channel) metadata=\(escapeControlChars(pad.metadata))")
    }

    static let handlePadContent: VerbHandler = { session, args in
        let channel = args[0]
        let flags = Array(args.dropFirst())
        let rawFlag = flags.contains("--raw")
        let jsonFlag = flags.contains("--json")
        if rawFlag && jsonFlag {
            throw CLIError.usage("--raw and --json are mutually exclusive")
        }
        let pad = try await session.getPadContent(channel: channel, cache: CLIReplState.shared.cache, userKey: Data())

        if rawFlag {
            switch pad.decoded {
            case .code(let cp):
                print(cp.content)
            case .slide(let sp):
                print(sp.content)
            case .pad, .unknown:
                throw CLIError.usage("--raw not supported for type=\(pad.type) (no flat string body; use default output or --json for the document JSON)")
            }
            return
        }

        if jsonFlag {
            print(pad.raw)
            return
        }

        let decodedStr: String
        switch pad.decoded {
        case .pad: decodedStr = "pad"
        case .code: decodedStr = "code"
        case .slide: decodedStr = "slide"
        case .unknown: decodedStr = "unknown"
        }
        if case .code(let cp) = pad.decoded {
            print("PAD-CONTENT OK channel=\(pad.channel) type=\(quotedField(pad.type)) decoded=\(decodedStr) highlightMode=\(quotedField(cp.highlightMode)) raw=\(escapeControlChars(pad.raw))")
        } else {
            print("PAD-CONTENT OK channel=\(pad.channel) type=\(quotedField(pad.type)) decoded=\(decodedStr) raw=\(escapeControlChars(pad.raw))")
        }
    }

    static let handlePadCreate: VerbHandler = { session, args in
        let title = args[0]
        let type = args.count >= 2 ? args[1] : "pad"
        let pad = try await session.createPad(title: title, type: type)
        print("PAD-CREATE OK href=\(pad.href) type=\(pad.type) title=\(pad.title)")
    }

    static let handlePadWatch: VerbHandler = { session, args in
        let channel = args[0]
        let printContent = args.dropFirst().contains("--print-content")

        let delegate = PadWatchDelegate(printContent: printContent)
        let pad = try await session.openPadSession(channel: channel, delegate: delegate)

        print("READY \(pad.channel) bytes=\(pad.initialContent.raw.utf8.count) readOnly=\(pad.isReadOnly) type=\(escapeControlChars(pad.initialContent.type))")

        await waitForSigint()

        print("EXIT closing session")
        await pad.closeAwait()
    }

    static let handlePadChatHistory: VerbHandler = { session, args in
        let channel = args[0]
        var requested: Int? = nil
        if let arg = args.dropFirst().first {
            guard let n = Int(arg), n > 0 else {
                throw CLIError.usage("pad chat-history: count must be a positive integer; got '\(arg)'")
            }
            requested = n
        }

        let chat = try await session.openPadChat(channel: channel, delegate: ChatWatchDelegate(quiet: true))
        var messages = chat.initialMessages
        if let want = requested, want > messages.count, let oldest = messages.first {
            let older = try await chat.loadMoreHistory(before: oldest.sig,
                                                       count: want - messages.count + 1)
            messages = older.reversed() + messages
        }
        print("PAD-CHAT-HISTORY OK padChannel=\(chat.padChannel) chatChannel=\(quotedField(chat.chatChannel)) count=\(messages.count)")
        for m in messages {
            printChatMessage(m)
        }
        await chat.closeAwait()
    }

    static let handlePadChatWatch: VerbHandler = { session, args in
        let channel = args[0]
        let delegate = ChatWatchDelegate(quiet: false)
        let chat = try await session.openPadChat(channel: channel, delegate: delegate)
        chatPrintLine("CHAT-READY padChannel=\(chat.padChannel) chatChannel=\(quotedField(chat.chatChannel)) buffered=\(chat.initialMessages.count)")
        for m in chat.initialMessages {
            printChatMessage(m)
        }

        await waitForSigint()

        chatPrintLine("EXIT closing chat")
        await chat.closeAwait()
    }

    static let handlePadChatSend: VerbHandler = { session, args in
        let channel = args[0]
        let text = args[1...].joined(separator: " ")
        let delegate = ChatSendEchoDelegate()
        let chat = try await session.openPadChat(channel: channel, delegate: delegate)
        try await chat.send(text)
        let echoed = await delegate.waitForEcho(text: text, timeoutMs: 3000)
        if let sig = echoed {
            print("PAD-CHAT-SEND OK padChannel=\(chat.padChannel) chatChannel=\(quotedField(chat.chatChannel)) sig=\(escapeControlChars(sig))")
        } else {
            print("PAD-CHAT-SEND OK padChannel=\(chat.padChannel) chatChannel=\(quotedField(chat.chatChannel)) sig=<echo not observed within 3s>")
        }
        await chat.closeAwait()
    }

    final class ChatSendEchoDelegate: PadChatSessionDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var received: [ChatMessage] = []

        func chatSession(_ chat: PadChatSession, didReceive message: ChatMessage) {
            lock.lock(); defer { lock.unlock() }
            received.append(message)
        }
        func chatSessionDidClear(_ chat: PadChatSession) {}
        func chatSession(_ chat: PadChatSession, didFail error: PadChatError) {
            FileHandle.standardError.write(Data("ERROR \(quotedField(chat.chatChannel)) code=\(error.rawValue)\n".utf8))
        }
        func chatSessionDidDisconnect(_ chat: PadChatSession) {
            FileHandle.standardError.write(Data("DISCONNECT \(quotedField(chat.chatChannel)) during echo wait\n".utf8))
        }

        private func echoSig(text: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return received.first(where: { $0.text == text })?.sig
        }

        func waitForEcho(text: String, timeoutMs: Int) async -> String? {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                if let sig = echoSig(text: text) { return sig }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return nil
        }
    }

    private static let chatPrintLock = NSLock()
    static func chatPrintLine(_ line: String) {
        chatPrintLock.lock(); defer { chatPrintLock.unlock() }
        print(line)
    }
    nonisolated(unsafe) private static let chatTimeFormatter = ISO8601DateFormatter()
    static func printChatMessage(_ m: ChatMessage) {
        chatPrintLock.lock()
        defer { chatPrintLock.unlock() }
        let iso = chatTimeFormatter.string(from: m.time)
        let name = m.authorName.map(quotedField) ?? "-"
        let text = escapeControlChars(m.text)
        print("MSG time=\(iso) author=\(m.authorCurvePublic.prefix(8))… name=\(name) sig=\(quotedField(m.sig)) text=\(text)")
    }

    final class ChatWatchDelegate: PadChatSessionDelegate, @unchecked Sendable {
        private let quiet: Bool
        init(quiet: Bool) { self.quiet = quiet }

        func chatSession(_ chat: PadChatSession, didReceive message: ChatMessage) {
            if quiet { return }
            SwiftPadCLI.printChatMessage(message)
        }

        func chatSessionDidClear(_ chat: PadChatSession) {
            if quiet { return }
            SwiftPadCLI.chatPrintLock.lock()
            defer { SwiftPadCLI.chatPrintLock.unlock() }
            print("CLEARED \(quotedField(chat.chatChannel)) — an owner cleared the history")
        }

        func chatSession(_ chat: PadChatSession, didFail error: PadChatError) {
            FileHandle.standardError.write(Data("ERROR \(quotedField(chat.chatChannel)) code=\(error.rawValue)\n".utf8))
        }

        func chatSessionDidDisconnect(_ chat: PadChatSession) {
            FileHandle.standardError.write(Data("DISCONNECT \(quotedField(chat.chatChannel)) (worker auto-rejoins on reconnect; ≤10 missed messages replay)\n".utf8))
        }
    }


    static func validateDMCurveFirst(_ verb: String) -> VerbValidator {
        return { args in
            guard let key = args.first, !key.isEmpty else {
                throw CLIError.usage("\(verb): missing <curvePublic> (see `contacts list`)")
            }
            guard key.count == 44, key.hasSuffix("="),
                  key.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber))
                                   || $0 == "+" || $0 == "/" || $0 == "=" }) else {
                throw CLIError.usage("\(verb): curvePublic must be a 44-char base64 curve25519 key (43 chars + '=' padding); got '\(key)'")
            }
        }
    }

    static let validateDMSend: VerbValidator = { args in
        try validateDMCurveFirst("dm send")(args)
        guard args.count >= 2, !args[1].isEmpty else {
            throw CLIError.usage("dm send: missing <text> (quote multi-word messages)")
        }
    }

    static let handleDMHistory: VerbHandler = { session, args in
        let curve = args[0]
        var requested: Int? = nil
        if let arg = args.dropFirst().first {
            guard let n = Int(arg), n > 0 else {
                throw CLIError.usage("dm history: count must be a positive integer; got '\(arg)'")
            }
            requested = n
        }

        let dm = try await session.openDirectMessages(with: curve, delegate: DMWatchDelegate(quiet: true))
        var messages = dm.initialMessages
        if let want = requested, want > messages.count, let oldest = messages.first {
            let older = try await dm.loadMoreHistory(before: oldest.sig,
                                                     count: want - messages.count + 1)
            messages = older.reversed() + messages
        }
        print("DM-HISTORY OK contact=\(dm.contactCurvePublic) channel=\(quotedField(dm.channelId)) count=\(messages.count)")
        for m in messages {
            printChatMessage(m)
        }
        await dm.closeAwait()
    }

    static let handleDMWatch: VerbHandler = { session, args in
        let delegate = DMWatchDelegate(quiet: false)
        let dm = try await session.openDirectMessages(with: args[0], delegate: delegate)
        chatPrintLine("DM-READY contact=\(dm.contactCurvePublic) channel=\(quotedField(dm.channelId)) buffered=\(dm.initialMessages.count)")
        for m in dm.initialMessages {
            printChatMessage(m)
        }

        await waitForSigint()

        chatPrintLine("EXIT closing dm")
        await dm.closeAwait()
    }

    static let handleDMSend: VerbHandler = { session, args in
        let text = args[1...].joined(separator: " ")
        let delegate = DMSendEchoDelegate()
        let dm = try await session.openDirectMessages(with: args[0], delegate: delegate)
        try await dm.send(text)
        let echoed = await delegate.waitForEcho(text: text, timeoutMs: 3000)
        if let sig = echoed {
            print("DM-SEND OK contact=\(dm.contactCurvePublic) channel=\(quotedField(dm.channelId)) sig=\(escapeControlChars(sig))")
        } else {
            print("DM-SEND OK contact=\(dm.contactCurvePublic) channel=\(quotedField(dm.channelId)) sig=<echo not observed within 3s>")
        }
        await dm.closeAwait()
    }

    final class DMWatchDelegate: DMChannelDelegate, @unchecked Sendable {
        private let quiet: Bool
        init(quiet: Bool) { self.quiet = quiet }

        func dmChannel(_ channel: DMChannel, didReceive message: ChatMessage) {
            if quiet { return }
            SwiftPadCLI.printChatMessage(message)
        }

        func dmChannelDidClear(_ channel: DMChannel) {
            if quiet { return }
            SwiftPadCLI.chatPrintLine("CLEARED \(SwiftPadCLI.quotedField(channel.channelId)) — history wiped or cursor reset")
        }

        func dmChannel(_ channel: DMChannel, didFail error: PadChatError) {
            FileHandle.standardError.write(Data("ERROR \(SwiftPadCLI.quotedField(channel.channelId)) code=\(error.rawValue)\n".utf8))
        }

        func dmChannelDidDisconnect(_ channel: DMChannel) {
            FileHandle.standardError.write(Data("DISCONNECT \(SwiftPadCLI.quotedField(channel.channelId)) (worker auto-rejoins; replays from the INIT_FRIENDS cursor)\n".utf8))
        }
    }

    final class DMSendEchoDelegate: DMChannelDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var received: [ChatMessage] = []

        func dmChannel(_ channel: DMChannel, didReceive message: ChatMessage) {
            lock.lock(); defer { lock.unlock() }
            received.append(message)
        }
        func dmChannelDidClear(_ channel: DMChannel) {}
        func dmChannel(_ channel: DMChannel, didFail error: PadChatError) {
            FileHandle.standardError.write(Data("ERROR \(SwiftPadCLI.quotedField(channel.channelId)) code=\(error.rawValue)\n".utf8))
        }
        func dmChannelDidDisconnect(_ channel: DMChannel) {
            FileHandle.standardError.write(Data("DISCONNECT \(SwiftPadCLI.quotedField(channel.channelId)) during echo wait\n".utf8))
        }

        private func echoSig(text: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return received.first(where: { $0.text == text })?.sig
        }

        func waitForEcho(text: String, timeoutMs: Int) async -> String? {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                if let sig = echoSig(text: text) { return sig }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return nil
        }
    }

    static func waitForSigint() async {
        let previousSigint = signal(SIGINT, SIG_IGN)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
            let resumeBox = SigintResumeBox()
            src.setEventHandler {
                if resumeBox.tryResume() {
                    src.cancel()
                    cont.resume()
                }
            }
            src.resume()
        }
        signal(SIGINT, previousSigint)
    }

    final class SigintResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func tryResume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    final class PadWatchDelegate: PadSessionDelegate, @unchecked Sendable {
        private let printContent: Bool
        private let lock = NSLock()
        private let startTime = Date()
        init(printContent: Bool) { self.printContent = printContent }

        func padSession(_ session: PadSession, didApplyPatch raw: String) {
            lock.lock(); defer { lock.unlock() }
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            if printContent {
                print("PATCH \(session.channel) bytes=\(raw.utf8.count) ms=\(elapsed) raw=\(escapeControlChars(raw))")
            } else {
                print("PATCH \(session.channel) bytes=\(raw.utf8.count) ms=\(elapsed)")
            }
        }

        func padSession(_ session: PadSession, didFail code: PadSessionError) {
            FileHandle.standardError.write(Data("ERROR \(session.channel) code=\(code.rawValue)\n".utf8))
        }

        func padSessionDidDisconnect(_ session: PadSession) {
            FileHandle.standardError.write(Data("DISCONNECT \(session.channel)\n".utf8))
        }
    }

    static let handlePadSet: VerbHandler = { session, args in
        let channel = args[0]
        let path = args[1]
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let raw = String(data: data, encoding: .utf8) else {
            throw CLIError.usage("pad set: file at '\(path)' is not valid UTF-8")
        }
        try await session.setPadContent(channel: channel, raw: raw)
        print("PAD-SET OK channel=\(channel) bytes=\(data.count)")
    }

    static let handlePadEdit: VerbHandler = { session, args in
        let channel = args[0]
        let pad = try await session.getPadContent(channel: channel, cache: CLIReplState.shared.cache, userKey: Data())

        let editText: String
        let fileExtension: String
        let editsContentField: Bool
        switch pad.decoded {
        case .code(let cp):
            editText = cp.content
            fileExtension = filenameExtensionFor(highlightMode: cp.highlightMode)
            editsContentField = true
        case .slide(let sp):
            editText = sp.content
            fileExtension = "md"
            editsContentField = true
        case .pad, .unknown:
            editText = pad.raw
            fileExtension = "json"
            editsContentField = false
        }

        let tmpName = "swiftpad-edit-\(channel.prefix(8))-\(Int(Date().timeIntervalSince1970)).\(fileExtension)"
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(tmpName)
        try Data(editText.utf8).write(to: tmpURL)

        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "vim"
        let escapedPath = tmpURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let waitStatus = libc_system("\(editor) '\(escapedPath)'")
        guard waitStatus == 0 else {
            let exitCode = (waitStatus >> 8) & 0xff
            let signalCode = waitStatus & 0x7f
            let detail = signalCode != 0 ? "killed by signal \(signalCode)" : "exit \(exitCode)"
            throw CLIError.usage("pad edit: editor failed (\(detail)); aborted; edits preserved at \(tmpURL.path)")
        }

        let edited: String
        do {
            edited = try String(contentsOf: tmpURL, encoding: .utf8)
        } catch {
            throw CLIError.usage("pad edit: could not read edited file at \(tmpURL.path): \(error.localizedDescription)")
        }

        if edited == editText {
            print("PAD-EDIT OK channel=\(channel) unchanged=true")
            try? FileManager.default.removeItem(at: tmpURL)
            return
        }

        let newRaw: String
        if editsContentField {
            guard let baseData = pad.raw.data(using: .utf8),
                  var obj = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any] else {
                throw CLIError.runtime("pad edit: could not re-parse pad envelope to wrap content; aborted; edits preserved at \(tmpURL.path)")
            }
            obj["content"] = edited
            guard let outData = try? JSONSerialization.data(withJSONObject: obj, options: []),
                  let outStr = String(data: outData, encoding: .utf8) else {
                throw CLIError.runtime("pad edit: could not re-serialize JSON; edits preserved at \(tmpURL.path)")
            }
            newRaw = outStr
        } else {
            if (try? JSONSerialization.jsonObject(with: Data(edited.utf8), options: [.allowFragments])) == nil {
                throw CLIError.runtime("pad edit: edited file is not valid JSON; aborted; edits preserved at \(tmpURL.path)")
            }
            newRaw = edited
        }

        do {
            try await session.setPadContent(channel: channel, raw: newRaw)
        } catch {
            throw CLIError.runtime("pad edit: server write failed (\(error)); edits preserved at \(tmpURL.path)")
        }
        try? FileManager.default.removeItem(at: tmpURL)
        print("PAD-EDIT OK channel=\(channel) bytes=\(newRaw.utf8.count)")
    }

    private static func filenameExtensionFor(highlightMode: String) -> String {
        switch highlightMode {
        case "gfm", "markdown": return "md"
        case "javascript": return "js"
        case "typescript": return "ts"
        case "python": return "py"
        case "swift": return "swift"
        case "ruby": return "rb"
        case "go": return "go"
        case "rust": return "rs"
        case "java": return "java"
        case "c": return "c"
        case "cpp", "c++": return "cpp"
        case "csharp", "c#": return "cs"
        case "css": return "css"
        case "html", "htmlmixed": return "html"
        case "xml": return "xml"
        case "json": return "json"
        case "yaml": return "yaml"
        case "shell", "bash": return "sh"
        case "sql": return "sql"
        case "lua": return "lua"
        case "perl": return "pl"
        case "haskell": return "hs"
        case "clojure": return "clj"
        default: return "txt"
        }
    }

    static let handlePadDuplicate: VerbHandler = { session, args in
        let sourceChannel = args[0]
        let newTitle = args[1...].joined(separator: " ")

        let sourcePad = try await session.getPadContent(channel: sourceChannel)

        guard sourcePad.type == "pad" || sourcePad.type == "code" else {
            throw CLIError.usage("pad duplicate: type=\(sourcePad.type) not supported yet (use pad/code; per-type seeds for slide/kanban/etc. queued for a phase-1 follow-up round)")
        }

        let created = try await session.createPad(title: newTitle, type: sourcePad.type)
        let entries = try await session.getDrive()
        guard let newEntry = entries.first(where: { $0.href == created.href }) else {
            throw CLIError.runtime("pad duplicate: created pad missing from drive (race?)")
        }

        let scrubbed = scrubDuplicateMetadata(raw: sourcePad.raw, type: sourcePad.type)

        try await session.setPadContent(channel: newEntry.channel, raw: scrubbed)
        print("PAD-DUPLICATE OK source=\(sourceChannel) new-channel=\(newEntry.channel) new-title=\(newTitle)")
    }

    private static func scrubDuplicateMetadata(raw: String, type: String) -> String {
        guard let data = raw.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) else {
            return raw
        }
        let scrubKeys: Set<String> = ["users", "chat2", "chat", "cursor"]
        let scrubMeta: ([String: Any]) -> [String: Any] = { meta in
            var out = meta
            for k in scrubKeys { out.removeValue(forKey: k) }
            return out
        }

        if type == "code", var dict = obj as? [String: Any] {
            if var meta = dict["metadata"] as? [String: Any] {
                meta = scrubMeta(meta)
                dict["metadata"] = meta
            }
            obj = dict
        } else if type == "pad", var arr = obj as? [Any], arr.count >= 4 {
            if var attrs = arr[3] as? [String: Any] {
                if var meta = attrs["metadata"] as? [String: Any] {
                    meta = scrubMeta(meta)
                    attrs["metadata"] = meta
                }
                arr[3] = attrs
            }
            obj = arr
        }

        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let str = String(data: out, encoding: .utf8) else {
            return raw
        }
        return str
    }

    static let handlePadDelete: VerbHandler = { session, args in
        let channel = args[0]
        try await session.deletePad(channel: channel)
        print("PAD-DELETE OK channel=\(channel)")
    }

    static let handlePadDestroy: VerbHandler = { session, args in
        let channel = args[0]
        try await session.destroyPad(channel: channel)
        print("PAD-DESTROY OK channel=\(channel)")
    }

    static let handlePadRename: VerbHandler = { session, args in
        let channel = args[0]
        let title = args[1...].joined(separator: " ")
        try await session.setPadTitle(channel: channel, title: title)
        print("PAD-RENAME OK channel=\(channel) title=\(title)")
    }

    static let handlePadPurgeTrash: VerbHandler = { session, _ in
        try await session.purgeTrash()
        print("PAD-PURGE-TRASH OK")
    }

    static let handlePadRestore: VerbHandler = { session, args in
        let channel = args[0]
        try await session.movePad(channel: channel, toPath: ["root"])
        print("PAD-RESTORE OK channel=\(channel)")
    }

    static let handlePadListDeleted: VerbHandler = { session, args in
        let candidates = args[0].split(separator: ",").map(String.init)
        let deleted = Set(try await session.getDeletedPads(candidates: candidates))
        for c in candidates {
            print("\(deleted.contains(c) ? "DELETED" : "LIVE") \(c)")
        }
    }

    static let handlePadShareLinks: VerbHandler = { session, args in
        let channel = args[0]
        let links = try await session.getShareLinks(channel: channel)
        let edit = links.edit ?? "(none)"
        print("SHARE-LINKS OK channel=\(channel) edit=\(edit) view=\(links.view) present=\(links.present) embed=\(links.embed)")
    }

    static let handleAccountInfo: VerbHandler = { session, _ in
        let info = try await session.getAccountInfo()
        let profile = info.profileUrl ?? "(none)"
        print("ACCOUNT OK edPublic=\(info.edPublic) curvePublic=\(info.curvePublic) notifications=\(info.notifications ?? "(none)") profileUrl=\(profile)")
    }


    static func showProfileField(_ v: String?) -> String {
        if let v, !v.isEmpty { return v }
        return "(none)"
    }

    static let handleAccountProfile: VerbHandler = { session, _ in
        let p = try await session.getProfile()
        print("PROFILE OK name=\(showProfileField(p.name)) channel=\(showProfileField(p.channel))")
        print("  description=\(showProfileField(p.description))")
        print("  url=\(showProfileField(p.url))")
        print("  avatar=\(showProfileField(p.avatar))")
    }

    static func validateValueArgPresent(_ verb: String, _ argName: String) -> VerbValidator {
        return { args in
            guard !args.isEmpty else {
                throw CLIError.usage("\(verb): missing <\(argName)> (use \"\" to clear)")
            }
        }
    }

    static let validateProfileUrlArg: VerbValidator = { args in
        try validateValueArgPresent("account set-url", "url")(args)
        guard args.count == 1 else {
            throw CLIError.usage("account set-url: one <url> arg (a URL has no spaces — quote it if it somehow does)")
        }
    }

    static let handleAccountSetDescription: VerbHandler = { session, args in
        let p = try await session.setProfileDescription(args.joined(separator: " "))
        print("PROFILE-SET OK description=\(showProfileField(p.description))")
    }

    static let handleAccountSetUrl: VerbHandler = { session, args in
        let p = try await session.setProfileUrl(args[0])
        print("PROFILE-SET OK url=\(showProfileField(p.url))")
    }

    static let validateAvatarPath: VerbValidator = { args in
        guard let path = args.first, !path.isEmpty else {
            throw CLIError.usage("account set-avatar: missing <path>")
        }
        let allowed = ["png", "jpg", "jpeg", "webp", "gif"]
        guard allowed.contains((path as NSString).pathExtension.lowercased()) else {
            throw CLIError.usage("account set-avatar: unsupported extension on '\(path)' (png/jpg/jpeg/webp/gif)")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw CLIError.usage("account set-avatar: '\(path)' does not exist or is a directory")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw CLIError.usage("account set-avatar: '\(path)' is not readable")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size: Int? = {
            if let n = attrs?[.size] as? Int { return n }
            if let u = attrs?[.size] as? UInt64, u <= UInt64(Int.max) { return Int(u) }
            if let n = attrs?[.size] as? NSNumber, n.uint64Value <= UInt64(Int.max) { return Int(n.uint64Value) }
            return nil
        }()
        if let size, size > 500_000 {
            throw CLIError.usage("account set-avatar: '\(path)' is \(size) bytes, over the 500000-byte cap (web clients render initials instead of avatars whose blob exceeds 512 KiB)")
        }
    }

    static let handleAccountSetAvatar: VerbHandler = { session, args in
        let path = args[0]
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let entry = try await session.setAvatar(
            imageData: data, mimeType: guessMimeType(forPath: path))
        print("AVATAR-SET OK bytes=\(data.count) channel=\(entry.channel) href=\(entry.href)")
    }

    static let handleAccountRemoveAvatar: VerbHandler = { session, _ in
        try await session.removeAvatar()
        print("AVATAR-REMOVE OK (blob + drive entry retained; delete via drive verbs if wanted)")
    }


    static func parseAttrPath(_ verb: String, _ raw: String?) throws -> [String] {
        guard let raw, !raw.isEmpty else {
            throw CLIError.usage("\(verb): missing <dotted.path> (e.g. general.autostore)")
        }
        let comps = raw.components(separatedBy: ".")
        guard comps.allSatisfy({ !$0.isEmpty }) else {
            throw CLIError.usage("\(verb): malformed path '\(raw)' (empty component)")
        }
        if comps[0] == "settings" {
            throw CLIError.usage("\(verb): paths are relative to proxy.settings — drop the leading 'settings.' (the worker adds it; keeping it mints a junk settings.settings subtree)")
        }
        if let bad = comps.first(where: { ["__proto__", "constructor", "prototype"].contains($0) }) {
            throw CLIError.usage("\(verb): path component '\(bad)' is not addressable (prototype-chain key)")
        }
        return comps
    }

    static func validateAttrPathOnly(_ verb: String) -> VerbValidator {
        return { args in _ = try parseAttrPath(verb, args.first) }
    }

    static let validateAttrSetBool: VerbValidator = { args in
        _ = try parseAttrPath("attr set-bool", args.first)
        guard args.count >= 2 else {
            throw CLIError.usage("attr set-bool: missing <true|false>")
        }
        guard args[1] == "true" || args[1] == "false" else {
            throw CLIError.usage("attr set-bool: value must be literally 'true' or 'false' (got '\(args[1])')")
        }
    }

    static let validateAttrSetInt: VerbValidator = { args in
        _ = try parseAttrPath("attr set-int", args.first)
        guard args.count >= 2 else {
            throw CLIError.usage("attr set-int: missing <integer>")
        }
        guard let n = Int(args[1]) else {
            throw CLIError.usage("attr set-int: value must be an integer within ±9007199254740991 (got '\(args[1])')")
        }
        guard n >= -9_007_199_254_740_991 && n <= 9_007_199_254_740_991 else {
            throw CLIError.usage("attr set-int: \(n) exceeds the JS safe-integer range (±9007199254740991)")
        }
    }

    static let validateAttrSetString: VerbValidator = { args in
        _ = try parseAttrPath("attr set-string", args.first)
        guard args.count >= 2 else {
            throw CLIError.usage("attr set-string: missing <value> (\"\" is legal — a stored empty string, NOT a delete; use attr clear to delete)")
        }
        guard args.count == 2 else {
            throw CLIError.usage("attr set-string: one <value> arg — quote multi-word values")
        }
    }

    static let handleAttrGet: VerbHandler = { session, args in
        let path = try parseAttrPath("attr get", args.first)
        let dotted = path.joined(separator: ".")
        if let json = try await session.getAttributeRawJSON(path: path) {
            print("ATTR-GET OK path=\(dotted) value=\(escapeControlChars(json))")
        } else {
            print("ATTR-GET OK path=\(dotted) value=(none)")
        }
    }

    static let handleAttrSetBool: VerbHandler = { session, args in
        let path = try parseAttrPath("attr set-bool", args.first)
        let value = args[1] == "true"
        try await session.setAttributeBool(path: path, value: value)
        print("ATTR-SET OK path=\(path.joined(separator: ".")) type=bool value=\(value)")
    }

    static let handleAttrSetInt: VerbHandler = { session, args in
        let path = try parseAttrPath("attr set-int", args.first)
        guard let value = Int(args[1]) else {
            throw CLIError.usage("attr set-int: value must be an integer (got '\(args[1])')")
        }
        try await session.setAttributeInt(path: path, value: value)
        print("ATTR-SET OK path=\(path.joined(separator: ".")) type=int value=\(value)")
    }

    static let handleAttrSetString: VerbHandler = { session, args in
        let path = try parseAttrPath("attr set-string", args.first)
        try await session.setAttribute(path: path, value: args[1])
        print("ATTR-SET OK path=\(path.joined(separator: ".")) type=string value=\(args[1])")
    }

    static let handleAttrClear: VerbHandler = { session, args in
        let path = try parseAttrPath("attr clear", args.first)
        try await session.setAttribute(path: path, value: nil)
        print("ATTR-CLEAR OK path=\(path.joined(separator: "."))")
    }


    static func teamListLine(id: String, _ t: TeamSummary) -> String {
        "  id=\(id) owner=\(t.owner) offline=\(t.offline) error=\(t.error)"
            + " name=\(escapeControlChars(t.name))"
    }

    static let handleTeamList: VerbHandler = { session, _ in
        let teams = try await session.listTeams()
        print("TEAM-LIST OK count=\(teams.count)")
        for (id, t) in teams.sorted(by: { $0.key < $1.key }) {
            print(teamListLine(id: id, t))
        }
    }

    static func teamInfoLine(_ meta: TeamMetadata) -> String {
        "TEAM-INFO OK name=\(quotedField(meta.name))"
            + " topic=\(meta.topic.map(quotedField) ?? "-")"
            + " avatar=\(meta.avatar?.isEmpty == false ? "set" : "none")"
            + " offline=\(meta.offline)"
    }

    static let handleTeamInfo: VerbHandler = { session, args in
        let meta = try await session.getTeamMetadata(teamId: args[0])
        print(teamInfoLine(meta))
    }

    static let handleTeamRoster: VerbHandler = { session, args in
        let roster = try await session.getTeamRoster(teamId: args[0])
        print("TEAM-ROSTER OK count=\(roster.count)")
        for (curve, m) in roster.sorted(by: { $0.key < $1.key }) {
            let name = trailingField(m.displayName)
            if m.pending == true {
                print("  curvePublic=\(quotedField(curve)) PENDING-INVITE remaining=\(m.remaining.map(String.init) ?? "?") name=\(name)")
            } else {
                print("  curvePublic=\(quotedField(curve)) role=\(m.role.wireValue) name=\(name)")
            }
        }
    }

    static let validateTeamCreate: VerbValidator = { args in
        guard let name = args.first,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("team create: missing or blank <name>")
        }
    }

    static let handleTeamCreate: VerbHandler = { session, args in
        let team = try await session.createTeam(name: args[0])
        print("TEAM-CREATE OK id=\(team.id) name=\(team.name) owner=\(team.owner)")
    }

    static let handleTeamLeave: VerbHandler = { session, args in
        try await session.leaveTeam(teamId: args[0])
        print("TEAM-LEAVE OK id=\(args[0])")
    }

    static let handleTeamDelete: VerbHandler = { session, args in
        try await session.deleteTeam(teamId: args[0])
        print("TEAM-DELETE OK id=\(args[0])")
    }

    static let handleTeamDrive: VerbHandler = { session, args in
        let entries = try await session.getTeamDrive(teamId: args[0])
        print("TEAM-DRIVE \(entries.count) entries")
        for e in entries {
            print(driveEntryLine(e))
        }
    }

    static let handleTeamUsage: VerbHandler = { session, args in
        let usage = try await session.getTeamPinnedUsage(teamId: args[0])
        let limit = try await session.getTeamPinLimit(teamId: args[0])
        print(limitLine("TEAM-USAGE bytes=\(usage.bytes)", limit))
    }

    static let handleTeamLimit: VerbHandler = { session, args in
        let limit = try await session.getTeamPinLimit(teamId: args[0])
        print(limitLine("TEAM-LIMIT", limit))
    }

    static let validateTeamRename: VerbValidator = { args in
        try validateTeamIdFirst("team rename")(args)
        guard args.count >= 2,
              !args[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("team rename: missing or blank <name>")
        }
    }

    static func validateTeamCurveSecond(_ verb: String) -> VerbValidator {
        return { args in
            try validateTeamIdFirst(verb)(args)
            guard args.count >= 2, !args[1].isEmpty else {
                throw CLIError.usage("\(verb): missing <curvePublic>")
            }
        }
    }

    static let handleTeamRename: VerbHandler = { session, args in
        let name = args[1...].joined(separator: " ")
        try await session.setTeamMetadata(teamId: args[0], name: name)
        print("TEAM-RENAME OK id=\(args[0]) name=\(name)")
    }

    static let handleTeamInvite: VerbHandler = { session, args in
        let contacts = try await session.listContacts()
        guard let contact = contacts[args[1]] else {
            throw CLIError.runtime("team invite: no contact with curvePublic \(args[1]) (see `contacts list`)")
        }
        try await session.inviteToTeam(teamId: args[0], contact: contact)
        print("TEAM-INVITE OK id=\(args[0]) invited=\(escapeControlChars(contact.displayName ?? args[1]))")
    }

    static let handleTeamKick: VerbHandler = { session, args in
        try await session.removeUser(teamId: args[0], curvePublic: args[1])
        print("TEAM-KICK OK id=\(args[0]) removed=\(args[1])")
    }

    static let validateTeamLinkCreate: VerbValidator = { args in
        try validateTeamIdFirst("team link-create")(args)
        guard args.count >= 2,
              !args[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("team link-create: missing or blank <name>")
        }
        if args.count >= 3, !["viewer", "member"].contains(args[2].lowercased()) {
            throw CLIError.usage("team link-create: role must be viewer or member; got '\(args[2])'")
        }
    }

    static func validateInviteURLFirst(_ verb: String) -> VerbValidator {
        return { args in
            guard args.count >= 1, !args[0].isEmpty else {
                throw CLIError.usage("\(verb): missing <url>")
            }
            guard let url = URL(string: args[0]),
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment != nil else {
                throw CLIError.usage("\(verb): not an invite URL (expected <origin>/teams/#/2/invite/edit/…)")
            }
        }
    }

    static let handleTeamLinkCreate: VerbHandler = { session, args in
        let role: TeamRole = (args.count >= 3 && args[2].lowercased() == "member") ? .member : .viewer
        let password = (args.count >= 4 && !args[3].isEmpty) ? args[3] : nil
        let url = try await session.createInviteLink(teamId: args[0], name: args[1],
                                                     role: role, password: password)
        print("TEAM-LINK-CREATE OK role=\(role.wireValue) password=\(password != nil)")
        print(url.absoluteString)
    }

    private static func inviteURLArg(_ raw: String, verb: String) throws -> URL {
        guard let url = URL(string: raw) else {
            throw CLIError.usage("\(verb): not a URL: '\(raw)'")
        }
        return url
    }

    static func linkPreviewLines(_ preview: InvitePreview) -> [String] {
        var lines = ["TEAM-LINK-PREVIEW OK team=\(quotedField(preview.teamName))"
            + " author=\(preview.authorDisplayName.map(quotedField) ?? "-")"
            + " password-required=\(preview.requiresPassword)"]
        if let message = preview.message {
            lines.append("  message: \(escapeControlChars(message))")
        }
        return lines
    }

    static let handleTeamLinkPreview: VerbHandler = { session, args in
        let preview = try await session.previewInviteLink(inviteURLArg(args[0], verb: "team link-preview"))
        for previewRow in linkPreviewLines(preview) { print(previewRow) }
    }

    static let handleTeamLinkAccept: VerbHandler = { session, args in
        let password = (args.count >= 2 && !args[1].isEmpty) ? args[1] : nil
        try await session.acceptInviteLink(inviteURLArg(args[0], verb: "team link-accept"), password: password)
        print("TEAM-LINK-ACCEPT OK — see `team list`")
    }

    static let handleContactsList: VerbHandler = { session, _ in
        let contacts = try await session.listContacts()
        print("CONTACTS-LIST OK count=\(contacts.count)")
        for (curve, c) in contacts.sorted(by: { $0.key < $1.key }) {
            print(contactLine(curvePublic: curve, c))
        }
    }

    static func contactLine(curvePublic: String, _ c: Contact) -> String {
        "  curvePublic=\(quotedField(curvePublic)) pending=\(c.pending) dm=\(c.hasDMChannel)"
            + " notifications=\(c.notifications.map(quotedField) ?? "-")"
            + " name=\(trailingField(c.displayName))"
    }

    static func escapeControlChars(_ s: String) -> String {
        DisplayText.escapeControlChars(s)
    }

    static func validateContactRequestArgs(_ verb: String) -> VerbValidator {
        return { args in
            try validateDMCurveFirst(verb)(args)
            guard args.count >= 2, !args[1].isEmpty else {
                throw CLIError.usage("\(verb): missing <notificationsChannel> (32 hex chars)")
            }
            guard args[1].count == 32,
                  args[1].allSatisfy({ $0.isASCII && $0.isHexDigit && !($0.isUppercase) }) else {
                throw CLIError.usage("\(verb): <notificationsChannel> must be 32 lowercase-hex chars, got '\(args[1])'")
            }
        }
    }

    static let handleContactsRequest: VerbHandler = { session, args in
        try await session.sendContactRequest(curvePublic: args[0], notifications: args[1])
        print("CONTACTS-REQUEST OK curvePublic=\(args[0]) (pending until answered — see `contacts list`)")
    }

    static let handleContactsCancel: VerbHandler = { session, args in
        try await session.cancelContactRequest(curvePublic: args[0])
        print("CONTACTS-CANCEL OK curvePublic=\(args[0])")
    }

    static func resolveIncomingRequest(_ session: SwiftPadSession,
                                       curvePublic: String,
                                       verb: String) async throws -> ContactRequest {
        let deadline = Date().addingTimeInterval(contactsRequestsPollDeadline)
        while true {
            let requests = try await session.listIncomingContactRequests()
            if let match = requests.first(where: { $0.from.curvePublic == curvePublic }) {
                return match
            }
            guard Date() < deadline else {
                throw CLIError.runtime("\(verb): no live request from \(curvePublic) after \(Int(contactsRequestsPollDeadline))s of polling (the list is eventually consistent — see `contacts requests`)")
            }
            try await Task.sleep(nanoseconds: contactsRequestsPollIntervalNs)
        }
    }

    static let handleContactsAccept: VerbHandler = { session, args in
        let request = try await resolveIncomingRequest(session, curvePublic: args[0], verb: "contacts accept")
        try await session.acceptContactRequest(request)
        print("CONTACTS-ACCEPT OK curvePublic=\(args[0]) (your side is a friend now; the requester converges after their worker's 3-9s+ delayed handler)")
    }

    static let handleContactsDecline: VerbHandler = { session, args in
        let request = try await resolveIncomingRequest(session, curvePublic: args[0], verb: "contacts decline")
        try await session.declineContactRequest(request)
        print("CONTACTS-DECLINE OK curvePublic=\(args[0]) (no trace remains on either side; they may ask again)")
    }

    static let handleContactsRemove: VerbHandler = { session, args in
        try await session.removeContact(curvePublic: args[0])
        print("CONTACTS-REMOVE OK curvePublic=\(args[0]) (their side converges when their worker processes the UNFRIEND)")
    }

    static let contactsRequestsPollDeadline: TimeInterval = 10
    static let contactsRequestsPollIntervalNs: UInt64 = 500_000_000

    static let handleContactsRequests: VerbHandler = { session, _ in
        let deadline = Date().addingTimeInterval(contactsRequestsPollDeadline)
        var requests = try await session.listIncomingContactRequests()
        var stable = false
        while !stable && Date() < deadline {
            try await Task.sleep(nanoseconds: contactsRequestsPollIntervalNs)
            let next = try await session.listIncomingContactRequests()
            stable = !next.isEmpty && next == requests
            requests = next
        }
        print("CONTACTS-REQUESTS OK count=\(requests.count)")
        for r in requests.sorted(by: { $0.from.curvePublic < $1.from.curvePublic }) {
            print(contactRequestLine(r))
        }
    }

    static func contactRequestLine(_ r: ContactRequest) -> String {
        "  curvePublic=\(quotedField(r.from.curvePublic)) hash=\(quotedField(r.hash))"
            + " name=\(trailingField(r.from.displayName))"
    }

    static let handleNotifList: VerbHandler = { session, _ in
        let deadline = Date().addingTimeInterval(contactsRequestsPollDeadline)
        var rows = try await session.listNotifications()
        var stable = false
        while !stable && Date() < deadline {
            try await Task.sleep(nanoseconds: contactsRequestsPollIntervalNs)
            let next = try await session.listNotifications()
            stable = !next.isEmpty && next == rows
            rows = next
        }
        print("NOTIF-LIST OK count=\(rows.count)")
        for n in rows.sorted(by: { ($0.box, $0.hash) < ($1.box, $1.hash) }) {
            print("  " + notifLine(n))
        }
    }

    static func notifLine(_ n: MailboxNotification) -> String {
        let time = n.time.map { chatTimeFormatterISO($0) } ?? "-"
        let preview = escapeControlChars(String(n.contentJSON.prefix(160)))
        return "box=\(quotedField(n.box)) time=\(time)"
            + " hash=\(quotedField(n.hash))"
            + " author=\(n.author.map(quotedField) ?? "-")"
            + " type=\(n.type.isEmpty ? "-" : quotedField(n.type))"
            + " content=\(preview)"
    }

    static func quotedField(_ s: String) -> String {
        DisplayText.quotedField(s)
    }

    static func trailingField(_ s: String?) -> String {
        DisplayText.trailingField(s)
    }

    static func chatTimeFormatterISO(_ d: Date) -> String {
        chatPrintLock.lock(); defer { chatPrintLock.unlock() }
        return chatTimeFormatter.string(from: d)
    }

    static let validateNotifAck: VerbValidator = { args in
        guard args.count == 2 else {
            throw CLIError.usage("notif ack: needs exactly <box> <hash> (both from `notif list`); got \(args.count) argument(s)")
        }
        guard !args[0].isEmpty else { throw CLIError.usage("notif ack: empty <box>") }
        guard !args[1].isEmpty else { throw CLIError.usage("notif ack: empty <hash>") }
    }

    static let handleNotifAck: VerbHandler = { session, args in
        let box = args[0], hash = args[1]
        let deadline = Date().addingTimeInterval(contactsRequestsPollDeadline)
        while Date() < deadline {
            let listed = try await session.listNotifications()
                .contains { $0.box == box && $0.hash == hash }
            if listed { break }
            try await Task.sleep(nanoseconds: contactsRequestsPollIntervalNs)
        }
        try await session.markNotificationRead(box: box, hash: hash)
        print("NOTIF-ACK OK box=\(box) hash=\(quotedField(hash))")
    }

    static let validateNotifHistory: VerbValidator = { args in
        guard let box = args.first, !box.isEmpty else {
            throw CLIError.usage("notif history: missing <box> (e.g. notifications)")
        }
        guard args.count <= 3 else {
            throw CLIError.usage("notif history: takes <box> [count] [before]; got \(args.count) arguments")
        }
        if args.count >= 2 {
            guard let n = Int(args[1]), n > 0, n <= 100 else {
                throw CLIError.usage("notif history: count must be an integer 1-100; got '\(args[1])'")
            }
        }
        if args.count == 3 {
            guard args[2].count == 64 else {
                throw CLIError.usage("notif history: before must be a 64-character hash from a previous page's `oldest=` field; got \(args[2].count) chars")
            }
        }
    }

    static let handleNotifHistory: VerbHandler = { session, args in
        let box = args[0]
        let count = args.count >= 2 ? (Int(args[1]) ?? 20) : 20
        let before = args.count == 3 ? args[2] : nil
        let page = try await session.notificationHistory(box: box, count: count, before: before)
        print("NOTIF-HISTORY OK box=\(box) rows=\(page.notifications.count) exhausted=\(page.exhausted) unreadable=\(page.unreadable) oldest=\(page.oldestHash.map(quotedField) ?? "-")")
        for n in page.notifications {
            print("  " + notifLine(n))
        }
    }

    static let handleNotifWatch: VerbHandler = { session, _ in
        _ = try await session.listNotifications()
        chatPrintLine("NOTIF-WATCH READY (Ctrl-C to exit)")
        let consumer = Task {
            for await ev in session.events {
                switch ev {
                case .mailboxMessage(let n):
                    chatPrintLine("NOTIF " + notifLine(n))
                case .mailboxViewed(let box, let hash):
                    chatPrintLine("NOTIF-VIEWED box=\(quotedField(box)) hash=\(quotedField(hash))")
                default:
                    break
                }
            }
        }
        await waitForSigint()
        consumer.cancel()
        chatPrintLine("EXIT notif watch")
    }

    static let handlePadSetTags: VerbHandler = { session, args in
        let channel = args[0]
        let tags = Array(args.dropFirst())
        try await session.setPadTags(channel: channel, tags: tags)
        print("PAD-SET-TAGS OK channel=\(channel) count=\(tags.count)")
    }

    static let handlePadGetTags: VerbHandler = { session, args in
        let channel = args[0]
        let tags = try await session.getPadTags(channel: channel)
        for tag in tags {
            print(escapeControlChars(tag))
        }
    }

    static let handlePadWarm: VerbHandler = { session, args in
        let channel = args[0]
        if let replCache = CLIReplState.shared.cache {
            try await session.warmPadCache(channel: channel, cache: replCache, userKey: Data())
            print("PAD-WARM OK channel=\(channel) result=repl-cache")
        } else {
            let backend = CLIInMemoryBlobStore()
            let cache = PadDocumentCache(backend: backend, policy: .biometricBound)
            try await session.warmPadCache(channel: channel, cache: cache, userKey: Data())
            let count = await backend.entryCount
            let result = (count > 0) ? "cached" : "no-checkpoint-skipped"
            print("PAD-WARM OK channel=\(channel) result=\(result)")
        }
    }

    static let handleCachesEvictAll: VerbHandler = { session, _ in
        let padCache = CLIReplState.shared.cache
        let driveCache = CLIReplState.shared.driveCache
        let username = CLIReplState.shared.username ?? "cli-repl"
        if padCache == nil && driveCache == nil {
            print("CACHES-EVICT-ALL OK no-op no-active-caches (one-shot mode — caches don't persist across CLI invocations)")
            return
        }
        guard let serverURL = CLIReplState.shared.serverURL else {
            print("CACHES-EVICT-ALL FAIL no server URL in REPL state — sign in first")
            return
        }
        let entries = try await session.getDrive()
        let channels = entries.map { $0.channel }
        try await SwiftPadSession.evictAllCaches(
            username: username,
            loginSalt: "",
            serverURL: serverURL,
            scryptCache: nil,
            padCache: padCache,
            padChannels: channels,
            driveCache: driveCache
        )
        let padCount = padCache != nil ? channels.count : 0
        let driveStatus = driveCache != nil ? "flushed" : "skipped"
        print("CACHES-EVICT-ALL OK pad-channels=\(padCount) drive=\(driveStatus) scrypt=skipped")
    }

    static let handleDriveCacheExport: VerbHandler = { session, _ in
        let snapshot = try await session.captureDriveSnapshot()
        print(snapshot)
    }


    static let handleCalendarList: VerbHandler = { session, _ in
        let calendars = try await session.listCalendars()
        print("CALENDAR-LIST OK count=\(calendars.count)")
        for c in calendars {
            var flags: [String] = []
            if c.readOnly { flags.append("read-only") }
            if c.loading { flags.append("loading") }
            if c.restricted { flags.append("restricted") }
            if c.offline { flags.append("offline") }
            if c.owned { flags.append("owned") }
            let teams = c.teams.map { $0 == "1" ? "personal" : ($0 == "0" ? "temp" : "team:\($0)") }
            print(calendarLine(c, flags: flags, stores: teams))
        }
    }

    static func calendarLine(_ c: CalendarInfo, flags: [String], stores: [String]) -> String {
        "  id=\(quotedField(c.id)) color=\(quotedField(c.color))"
            + " stores=\(stores.joined(separator: ","))"
            + " \(flags.isEmpty ? "-" : flags.joined(separator: ","))"
            + " title=\(escapeControlChars(c.title))"
    }

    static let handleCalendarEvents: VerbHandler = { session, args in
        let events = try await session.listCalendarEvents(calendarId: args[0])
        print("CALENDAR-EVENTS OK count=\(events.count)")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm"
        for e in events {
            let when: String
            if e.isAllDay, let d = e.startDay {
                when = "all-day \(quotedField(d))"
                    + (e.endDay.map { $0 == e.startDay ? "" : "..\(quotedField($0))" } ?? "")
            } else if let s = e.startMs {
                let start = df.string(from: Date(timeIntervalSince1970: s / 1000))
                let end = e.endMs.map { " to " + df.string(from: Date(timeIntervalSince1970: $0 / 1000)) } ?? ""
                when = start + end
            } else {
                when = "no-numeric-start"
            }
            var flags: [String] = []
            if e.isRecurring { flags.append("recurring") }
            if !e.reminders.isEmpty {
                let rendered = e.reminders.map { r -> String in
                    if let i = Int(exactly: r.rounded()), Double(i) == r { return String(i) }
                    return String(r)
                }
                flags.append("reminders=\(rendered.joined(separator: ","))")
            }
            print(eventLine(e, when: when, flags: flags))
        }
    }

    static func eventLine(_ e: CalendarEvent, when: String, flags: [String]) -> String {
        "  id=\(quotedField(e.id)) \(when)"
            + " \(flags.isEmpty ? "-" : flags.joined(separator: " "))"
            + " title=\(escapeControlChars(e.title))"
    }

    static let validateCalendarCreate: VerbValidator = { args in
        guard let title = args.first,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("calendar create: missing or blank <title>")
        }
        if args.count >= 2, args[1].range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil {
            throw CLIError.usage("calendar create: color must be #rrggbb; got '\(args[1])'")
        }
    }

    static let handleCalendarCreate: VerbHandler = { session, args in
        let color = args.count >= 2 ? args[1] : "#3771fb"
        let id = try await session.createCalendar(title: args[0], color: color)
        print("CALENDAR-CREATE OK id=\(id) color=\(color) title=\(args[0])")
    }

    static let validateCalendarRename: VerbValidator = { args in
        try validateChannelFirst("calendar rename")(args)
        guard args.count >= 2,
              !args[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("calendar rename: missing or blank <title>")
        }
    }

    static let handleCalendarRename: VerbHandler = { session, args in
        let title = args[1...].joined(separator: " ")
        try await session.updateCalendar(calendarId: args[0], title: title)
        print("CALENDAR-RENAME OK id=\(args[0]) title=\(title)")
    }

    static let validateCalendarRecolor: VerbValidator = { args in
        try validateChannelFirst("calendar recolor")(args)
        guard args.count >= 2,
              args[1].range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            throw CLIError.usage("calendar recolor: missing color (#rrggbb)")
        }
    }

    static let handleCalendarRecolor: VerbHandler = { session, args in
        try await session.updateCalendar(calendarId: args[0], color: args[1])
        print("CALENDAR-RECOLOR OK id=\(args[0]) color=\(args[1])")
    }

    static let handleCalendarDelete: VerbHandler = { session, args in
        try await session.deleteCalendar(calendarId: args[0])
        print("CALENDAR-DELETE OK id=\(args[0])")
    }

    static func parseEventDate(_ s: String, verb: String) throws -> (date: Date, allDay: Bool) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        if s.count == 10 {
            df.dateFormat = "yyyy-MM-dd"
            guard let d = df.date(from: s) else {
                throw CLIError.usage("\(verb): '\(s)' is not YYYY-MM-DD")
            }
            return (d, true)
        }
        df.dateFormat = "yyyy-MM-dd'T'HH:mm"
        guard let d = df.date(from: s) else {
            throw CLIError.usage("\(verb): '\(s)' is not YYYY-MM-DDTHH:MM (or YYYY-MM-DD for all-day)")
        }
        return (d, false)
    }

    static func endOfLocalDay(_ d: Date) -> Date {
        Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: d)
            ?? d.addingTimeInterval(86_399)
    }

    static let validateEventCreate: VerbValidator = { args in
        try validateChannelFirst("event create")(args)
        guard args.count >= 2,
              !args[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("event create: missing or blank <title> (quote multi-word titles)")
        }
        guard args.count >= 3 else {
            throw CLIError.usage("event create: missing <start> (YYYY-MM-DDTHH:MM or YYYY-MM-DD)")
        }
        let (start, _) = try parseEventDate(args[2], verb: "event create")
        if args.count >= 4 {
            let (end, _) = try parseEventDate(args[3], verb: "event create")
            guard end >= start else {
                throw CLIError.usage("event create: <end> is before <start> — other clients would render a negative-duration event")
            }
        }
    }

    static let handleEventCreate: VerbHandler = { session, args in
        let (start, allDay) = try parseEventDate(args[2], verb: "event create")
        let end: Date
        if args.count >= 4 {
            let (e, endAllDay) = try parseEventDate(args[3], verb: "event create")
            guard endAllDay == allDay else {
                throw CLIError.usage("event create: start and end must both be timed or both all-day")
            }
            end = endAllDay ? endOfLocalDay(e) : e
        } else {
            end = allDay ? endOfLocalDay(start) : start.addingTimeInterval(3_600)
        }
        let id = try await session.createCalendarEvent(
            calendarId: args[0], title: args[1],
            startMs: start.timeIntervalSince1970 * 1000,
            endMs: end.timeIntervalSince1970 * 1000,
            isAllDay: allDay)
        print("EVENT-CREATE OK calendar=\(args[0]) id=\(id) allDay=\(allDay) title=\(args[1])")
    }

    static let eventSetFields = ["title", "location", "body", "start", "end", "reminders"]

    static let validateEventSet: VerbValidator = { args in
        try validateChannelFirst("event set")(args)
        guard args.count >= 2, !args[1].isEmpty else {
            throw CLIError.usage("event set: missing <eventId>")
        }
        guard !args[1].contains("|") else {
            throw CLIError.usage("event set: occurrence ids (uid|start) are not editable — recurring events are web-client-only this version")
        }
        guard args.count >= 3, eventSetFields.contains(args[2]) else {
            throw CLIError.usage("event set: field must be one of \(eventSetFields.joined(separator: "|"))")
        }
        guard args.count >= 4 else {
            throw CLIError.usage("event set: missing <value>")
        }
        let value = args[3...].joined(separator: " ")
        if args[2] == "start" || args[2] == "end" {
            _ = try parseEventDate(value, verb: "event set")
        }
        if args[2] == "reminders" {
            _ = try parseRemindersValue(value)
        }
    }

    static func parseRemindersValue(_ value: String) throws -> [Double] {
        if value == "none" { return [] }
        let parts = value.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else {
            throw CLIError.usage("event set: reminders must be comma-separated minutes (e.g. 10,60) or 'none'")
        }
        return parts.compactMap { $0 }
    }

    static let handleEventSet: VerbHandler = { session, args in
        let field = args[2]
        let value = args[3...].joined(separator: " ")
        var changes = CalendarEventChanges()
        switch field {
        case "title": changes.title = value
        case "location": changes.location = value
        case "body": changes.body = value
        case "start", "end":
            let (d, allDay) = try parseEventDate(value, verb: "event set")
            if field == "start" {
                changes.startMs = d.timeIntervalSince1970 * 1000
            } else {
                let end = allDay ? endOfLocalDay(d) : d
                changes.endMs = end.timeIntervalSince1970 * 1000
            }
        case "reminders":
            changes.reminders = try parseRemindersValue(value)
        default:
            throw CLIError.usage("event set: unknown field '\(field)'")
        }
        try await session.updateCalendarEvent(calendarId: args[0], eventId: args[1], changes: changes)
        print("EVENT-SET OK calendar=\(args[0]) id=\(args[1]) \(field) updated")
    }

    static let validateEventDelete: VerbValidator = { args in
        try validateChannelFirst("event delete")(args)
        guard args.count >= 2, !args[1].isEmpty else {
            throw CLIError.usage("event delete: missing <eventId>")
        }
        guard !args[1].contains("|") else {
            throw CLIError.usage("event delete: occurrence ids (uid|start) cannot be deleted — whole events only this version")
        }
    }

    static let handleEventDelete: VerbHandler = { session, args in
        try await session.deleteCalendarEvent(calendarId: args[0], eventId: args[1])
        print("EVENT-DELETE OK calendar=\(args[0]) id=\(args[1])")
    }

    static let handleFileGet: VerbHandler = { session, args in
        let channel = args[0]
        let outputPath = args[1]
        let fm = FileManager.default
        let partialPath = outputPath + ".swiftpad-partial"
        if fm.fileExists(atPath: partialPath) {
            try fm.removeItem(atPath: partialPath)
        }
        guard fm.createFile(atPath: partialPath, contents: nil) else {
            throw CLIError.runtime("file get: failed to create temp file at '\(partialPath)'")
        }
        guard let handle = FileHandle(forWritingAtPath: partialPath) else {
            try? fm.removeItem(atPath: partialPath)
            throw CLIError.runtime("file get: failed to open '\(partialPath)' for writing")
        }

        let stream: FileBlobStream
        var bytes = 0
        do {
            stream = try await session.streamFileContent(channel: channel)
            for try await chunk in stream.chunks {
                try handle.write(contentsOf: chunk)
                bytes += chunk.count
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(atPath: partialPath)
            throw error
        }
        if fm.fileExists(atPath: outputPath) {
            try fm.removeItem(atPath: outputPath)
        }
        try fm.moveItem(atPath: partialPath, toPath: outputPath)

        print(fileGetLine(channel: channel, bytes: bytes, metadata: stream.metadata))
    }

    static func fileGetLine(channel: String, bytes: Int, metadata: FileBlobMetadata) -> String {
        "FILE-GET OK channel=\(channel) bytes=\(bytes)"
            + " mime=\(quotedField(metadata.mimeType))"
            + " name=\(escapeControlChars(metadata.name))"
    }

    static let handleFileUp: VerbHandler = { session, args in
        let inputPath = args[0]
        let basename = (inputPath as NSString).lastPathComponent
        var title: String? = nil
        var mime: String? = nil
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--title":
                title = args[i + 1]; i += 2
            case "--mime":
                mime = args[i + 1]; i += 2
            default:
                throw CLIError.usage("file up: unknown flag '\(args[i])'")
            }
        }
        let resolvedMime = mime ?? guessMimeType(forPath: inputPath)

        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: inputPath)
        let totalBytes: Int
        if let n = attrs[.size] as? Int {
            totalBytes = n
        } else if let u = attrs[.size] as? UInt64, u <= UInt64(Int.max) {
            totalBytes = Int(u)
        } else if let n = attrs[.size] as? NSNumber, n.uint64Value <= UInt64(Int.max) {
            totalBytes = Int(n.uint64Value)
        } else {
            throw CLIError.usage("file up: cannot stat '\(inputPath)' or size exceeds Int.max")
        }

        let chunkSize = 131_072
        guard let handle = FileHandle(forReadingAtPath: inputPath) else {
            throw CLIError.usage("file up: cannot open '\(inputPath)' for reading")
        }
        let reader = FileUpChunkReader(handle: handle, chunkSize: chunkSize)
        let stream = AsyncStream<Data>(unfolding: { reader.next() })

        let progress: @Sendable (FileUploadProgress) -> Void = { p in
            FileHandle.standardError.write(
                Data("FILE-UP PROGRESS bytes=\(p.bytesUploaded)/\(p.bytesEstimate)\n".utf8))
        }

        let entry = try await session.uploadFile(
            plaintext: stream,
            totalBytes: totalBytes,
            name: basename,
            mimeType: resolvedMime,
            title: title,
            progress: progress
        )

        print("FILE-UP OK channel=\(entry.channel) bytes=\(totalBytes) mime=\(resolvedMime) name=\(basename)")
    }

    static let handlePadWarmAll: VerbHandler = { session, _ in
        let entries = try await session.getDrive()
        let cache = CLIReplState.shared.cache
            ?? PadDocumentCache(backend: CLIInMemoryBlobStore(), policy: .biometricBound)
        var ok = 0
        var failed = 0
        for entry in entries {
            do {
                try await session.warmPadCache(channel: entry.channel, cache: cache, userKey: Data())
                ok += 1
            } catch {
                failed += 1
                FileHandle.standardError.write(Data("PAD-WARM-ALL skip channel=\(quotedField(entry.channel)) error=\(escapeControlChars("\(error)"))\n".utf8))
            }
        }
        print("PAD-WARM-ALL OK total=\(entries.count) succeeded=\(ok) failed=\(failed)")
    }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case runtime(String)
    var description: String {
        switch self {
        case .usage(let msg): return msg
        case .runtime(let msg): return msg
        }
    }
}

private final class FileUpChunkReader: @unchecked Sendable {
    private let handle: FileHandle
    private let chunkSize: Int
    private var finished = false

    init(handle: FileHandle, chunkSize: Int) {
        self.handle = handle
        self.chunkSize = chunkSize
    }

    deinit { if !finished { try? handle.close() } }

    func next() -> Data? {
        if finished { return nil }
        return autoreleasepool {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty {
                finished = true
                try? handle.close()
                return nil
            }
            return data
        }
    }
}
#else
import Foundation
@main struct SwiftPadCLIUnavailable {
    static func main() {
        FileHandle.standardError.write(Data("swiftpad-cli is macOS-only\n".utf8))
        exit(2)
    }
}
#endif
