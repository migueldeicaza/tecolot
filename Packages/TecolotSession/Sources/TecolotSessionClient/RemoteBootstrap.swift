import Foundation

public enum RemoteBootstrapError: Error, CustomStringConvertible, Sendable {
    case invalidComponent(String)
    case invalidResponse(String)
    case unsupportedBinary(String)

    public var description: String {
        switch self {
        case .invalidComponent(let value): return "Invalid bootstrap value: \(value)"
        case .invalidResponse(let value): return value
        case .unsupportedBinary(let value): return "This host is not supported (\(value))."
        }
    }
}

public struct RemoteLayout: Hashable, Sendable {
    public let baseDirectory: String
    public let runtimeDirectory: String?

    public init(baseDirectory: String = ".tecolot", runtimeDirectory: String? = nil) throws {
        try RemoteBootstrap.validatePath(baseDirectory, absolute: false)
        if let runtimeDirectory { try RemoteBootstrap.validatePath(runtimeDirectory, absolute: true) }
        self.baseDirectory = baseDirectory
        self.runtimeDirectory = runtimeDirectory
    }
}

public struct RemoteProbeResult: Hashable, Sendable {
    public let fields: [String: String]
    public var os: String { fields["os"] ?? "" }
    public var arch: String { fields["arch"] ?? "" }
    public var binaryID: String? { fields["binary"].flatMap { $0 == "unsupported" ? nil : $0 } }
    public var release: String { fields["release"] ?? "" }
    public var installedHash: String? { fields["installed"].flatMap { $0 == "none" ? nil : $0 } }
    public var runs: Bool { fields["runs"] == "1" }
    public var homeOK: Bool { fields["home-ok"] == "1" }
    public var runtimeOK: Bool { fields["runtime-ok"] == "1" }
    public var runtimeDirectory: String { fields["runtime"] ?? "" }
    public var hasGzip: Bool { fields["gzip"] == "1" }
    public var hasHashTool: Bool { fields["hash-tool"] == "1" }
    public var receiverReady: Bool { fields["receiver"] == "1" }
    public var receivePath: String? { fields["receive"].flatMap { $0.isEmpty ? nil : $0 } }
    public var expectedHash: String? { fields["expected"].flatMap { $0 == "none" ? nil : $0 } }
    public var needsUpload: Bool { installedHash != expectedHash || !runs }
}

public typealias ProbeResult = RemoteProbeResult

public struct RemoteUploadStep: Hashable, Sendable {
    public let step: String
    public let succeeded: Bool
    public let detail: String
}

/// POSIX scripts for a probe channel and a separate binary upload channel.
public struct RemoteBootstrap: Sendable {
    public let layout: RemoteLayout
    public let metadata: [RemoteHelperMetadata]

    public init(layout: RemoteLayout = try! RemoteLayout(), metadata: [RemoteHelperMetadata]) throws {
        for item in metadata {
            try Self.validateComponent(item.binaryID)
            try Self.validateComponent(item.version)
            guard item.uncompressedSize >= 0 else {
                throw RemoteBootstrapError.invalidResponse("The helper size is invalid")
            }
            guard item.sha256.count == 64, item.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw RemoteBootstrapError.invalidComponent(item.sha256)
            }
            guard ["linux-x86_64", "linux-aarch64", "darwin-universal"].contains(item.binaryID) else {
                throw RemoteBootstrapError.unsupportedBinary(item.binaryID)
            }
        }
        guard Set(metadata.map(\.binaryID)).count == metadata.count else {
            throw RemoteBootstrapError.invalidResponse("Duplicate helper metadata")
        }
        self.layout = layout
        self.metadata = metadata
    }

    public static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }), value != ".", value != ".." else { throw RemoteBootstrapError.invalidComponent(value) }
    }

    static func validatePath(_ value: String, absolute: Bool) throws {
        guard value.hasPrefix("/") == absolute else { throw RemoteBootstrapError.invalidComponent(value) }
        let parts = (absolute ? String(value.dropFirst()) : value).split(separator: "/", omittingEmptySubsequences: false)
        for part in parts { try validateComponent(String(part)) }
    }

    public func receiverCommand(nonce: String) throws -> String {
        try Self.validateComponent(nonce)
        return "/bin/sh ./\(layout.baseDirectory)/tmp/\(nonce)/receive"
    }

    /// Deletes the helper directory. The command runs in the home directory.
    public func removeCommand() throws -> [String] {
        try Self.validatePath(layout.baseDirectory, absolute: false)
        return ["rm", "-rf", "--", "./\(layout.baseDirectory)"]
    }

    public func bridgeCommand(probe: RemoteProbeResult, nonce: String) throws -> String {
        try Self.validateComponent(nonce)
        guard let binary = probe.binaryID else { throw RemoteBootstrapError.unsupportedBinary("\(probe.os), \(probe.arch)") }
        try Self.validateComponent(binary)
        try Self.validateComponent(probe.release)
        try Self.validatePath(probe.runtimeDirectory, absolute: true)
        return "\(layout.baseDirectory)/bin/\(binary)/\(probe.release)/tecolot-sessiond bridge --stdio --nonce \(nonce) --runtime-dir \(probe.runtimeDirectory)"
    }

    public func parseProbe(_ output: String, nonce: String) throws -> RemoteProbeResult {
        try Self.validateComponent(nonce)
        let begin = "TECOLOT-PROBE-BEGIN \(nonce)"
        let end = "TECOLOT-PROBE-END \(nonce)"
        var fields: [String: String] = [:]
        var inside = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]
            if line == begin { fields.removeAll(); inside = true; continue }
            if line == end, inside {
                let required = ["os", "arch", "binary", "installed", "runs", "home-ok", "runtime", "runtime-ok", "gzip", "receiver", "expected", "release"]
                guard required.allSatisfy({ fields[$0] != nil }) else { throw RemoteBootstrapError.invalidResponse("The host sent an incomplete probe result") }
                return RemoteProbeResult(fields: fields)
            }
            guard inside, let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            guard fields[key] == nil else { throw RemoteBootstrapError.invalidResponse("The host sent a duplicate probe field") }
            fields[key] = String(line[line.index(after: equals)...])
        }
        throw RemoteBootstrapError.invalidResponse("The host did not send a complete probe result")
    }

    public func parseUploadSteps(_ output: String, nonce: String) throws -> [RemoteUploadStep] {
        try Self.validateComponent(nonce)
        let prefix = "TECOLOT-STEP \(nonce) "
        return output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix(prefix) else { return nil }
            let values = line.dropFirst(prefix.count).split(separator: " ", maxSplits: 2)
            guard values.count >= 2, values[1] == "ok" || values[1] == "fail" else { return nil }
            return RemoteUploadStep(step: String(values[0]), succeeded: values[1] == "ok",
                                    detail: values.count == 3 ? String(values[2]) : "")
        }
    }

    public func probeScript(nonce: String) throws -> String {
        try Self.validateComponent(nonce)
        let choices = metadata.map { "\($0.binaryID)) expected='\($0.sha256)'; release='\($0.release)' ;;" }.joined(separator: "\n")
        let runtime = layout.runtimeDirectory.map { "runtime='\($0)'" } ?? "runtime=\"/tmp/tecolot-$uid\""
        let receiver = receiverScript()
        return #"""
        #!/bin/sh
        umask 077
        nonce='\#(nonce)'
        relative_base='\#(layout.baseDirectory)'
        base="$HOME/$relative_base"
        uid=$(id -u)
        \#(runtime)
        \#(Self.shellUtilities)
        os=$(uname -s); arch=$(uname -m)
        binary=unsupported
        case "$os:$arch" in
          Linux:x86_64|Linux:amd64) binary=linux-x86_64 ;;
          Linux:aarch64|Linux:arm64) binary=linux-aarch64 ;;
          Darwin:arm64|Darwin:x86_64) binary=darwin-universal ;;
        esac
        expected=none; release=none
        case "$binary" in
        \#(choices)
        esac
        hash_tool=0
        for tool in sha256sum shasum openssl; do command -v "$tool" >/dev/null 2>&1 && hash_tool=1; done
        home_ok=0; runtime_ok=0; installed=none; runs=0; receiver=0; receive=; gzip_ok=0
        command -v gzip >/dev/null 2>&1 && gzip_ok=1
        prepare_base && home_ok=1
        if [ ! -e "$runtime" ] && [ ! -L "$runtime" ]; then mkdir "$runtime" 2>/dev/null; fi
        private_dir "$runtime" && runtime_ok=1
        if [ "$home_ok" = 1 ] && [ "$expected" != none ]; then
          destination="$base/bin/$binary/$release"
          if private_dir "$base/bin" && private_dir "$base/bin/$binary" && private_dir "$destination" && [ -f "$destination/tecolot-sessiond" ] && [ ! -L "$destination/tecolot-sessiond" ]; then
            installed=$(hash_file "$destination/tecolot-sessiond") || installed=none
            "$destination/tecolot-sessiond" version --json >/dev/null 2>&1 && runs=1
          fi
          if [ "$runtime_ok" = 1 ] && { [ "$installed" != "$expected" ] || [ "$runs" != 1 ]; }; then
            if ensure_private "$base/tmp" && mkdir "$base/tmp/$nonce" 2>/dev/null; then
              work="$base/tmp/$nonce"
              {
                printf '%s\n' '#!/bin/sh' "nonce='$nonce'" "relative_base='\#(layout.baseDirectory)'" "binary='$binary'" "release='$release'" "expected='$expected'" "compressed='$gzip_ok'"
                cat <<'TECOLOT_RECEIVER_BODY'
        \#(receiver)
        TECOLOT_RECEIVER_BODY
              } > "$work/receive" && chmod 700 "$work/receive" && receiver=1
              if [ "$receiver" = 1 ]; then receive="$relative_base/tmp/$nonce/receive"; else rm -rf "$work"; fi
            fi
          fi
        fi
        libc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || libc=unknown
        if [ "$libc" = unknown ] && command -v ldd >/dev/null 2>&1; then
          case "$(ldd --version 2>&1)" in *musl*) libc=musl ;; esac
        fi
        host=$(hostname 2>/dev/null)
        login_shell=${SHELL-}
        if command -v getent >/dev/null 2>&1; then
          account=$(getent passwd "$uid" 2>/dev/null)
          [ -z "$account" ] || login_shell=$(printf '%s\n' "$account" | awk -F: '{print $7}')
        fi
        kill_processes=; linger=
        if command -v loginctl >/dev/null 2>&1; then
          linger=$(loginctl show-user "$uid" -p Linger --value 2>/dev/null)
          manager_properties=$(loginctl show-user -p KillUserProcesses -p KillExcludeUsers 2>/dev/null)
          manager_kill=; kill_exclude_users=
          while IFS= read -r property; do
            case "$property" in
              KillUserProcesses=*) manager_kill=${property#KillUserProcesses=} ;;
              KillExcludeUsers=*) kill_exclude_users=${property#KillExcludeUsers=} ;;
            esac
          done <<TECOLOT_MANAGER_PROPERTIES
        $manager_properties
        TECOLOT_MANAGER_PROPERTIES
          if [ "$manager_kill" = yes ]; then
            remote_user=$(id -un 2>/dev/null)
            if [ -n "$remote_user" ]; then
              kill_processes=yes
              case " $kill_exclude_users " in *" $remote_user "*) kill_processes=no ;; esac
            fi
          elif [ "$manager_kill" = no ]; then
            kill_processes=no
          fi
        fi
        printf '%s\n' "TECOLOT-PROBE-BEGIN $nonce" "os=$os" "arch=$arch" "binary=$binary" "libc=$libc" "host=$host" "uid=$uid" "shell=$login_shell" "home-ok=$home_ok" "installed=$installed" "expected=$expected" "release=$release" "runs=$runs" "runtime=$runtime" "runtime-ok=$runtime_ok" "gzip=$gzip_ok" "hash-tool=$hash_tool" "receiver=$receiver" "receive=$receive" "kill-user-processes=$kill_processes" "linger=$linger" "TECOLOT-PROBE-END $nonce"
        """# + "\n"
    }

    private static let shellUtilities = #"""
    file_info() {
      stat -c '%u %a' "$1" 2>/dev/null || stat -f '%u %Lp' "$1" 2>/dev/null
    }
    safe_home() {
      [ -d "$1" ] && [ ! -L "$1" ] || return 1
      info=$(file_info "$1") || return 1
      set -- $info
      [ "$#" = 2 ] && [ "$1" = "$uid" ] || return 1
      case "$2" in *[!0-7]*|'') return 1 ;; esac
      [ "$((0$2 & 022))" = 0 ]
    }
    prepare_base() {
      current="$HOME"; remaining="$relative_base"
      while [ -n "$remaining" ]; do
        case "$remaining" in
          */*) component=${remaining%%/*}; remaining=${remaining#*/} ;;
          *) component=$remaining; remaining= ;;
        esac
        current="$current/$component"
        if [ ! -e "$current" ] && [ ! -L "$current" ]; then mkdir "$current" 2>/dev/null; fi
        safe_home "$current" || return 1
      done
    }
    private_dir() {
      [ -d "$1" ] && [ ! -L "$1" ] || return 1
      [ "$(file_info "$1")" = "$uid 700" ]
    }
    ensure_private() {
      if [ ! -e "$1" ] && [ ! -L "$1" ]; then mkdir "$1" 2>/dev/null || private_dir "$1" || return 1; fi
      private_dir "$1"
    }
    hash_file() {
      if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
      elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
      elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r "$1" | awk '{print $1}'
      else return 1
      fi
    }
    """#

    private func receiverScript() -> String {
        #"""
        umask 077
        base="$HOME/$relative_base"
        uid=$(id -u)
        work="$base/tmp/$nonce"
        lock_owned=0
        \#(Self.shellUtilities)
        report() { printf '%s\n' "TECOLOT-STEP $nonce $1 $2 ${3-}"; }
        fail() { report "$1" fail "$2"; exit 1; }
        cleanup() {
          [ "$lock_owned" = 0 ] || rmdir "$lock" 2>/dev/null
          rm -rf "$work"
        }
        safe_home "$base" && private_dir "$base/tmp" && private_dir "$work" || fail prepare 'The helper directory is not safe'
        trap cleanup 0
        trap 'exit 1' 1 2 3 15
        stage="$work/stage"
        mkdir "$stage" || fail prepare 'Cannot create the upload directory; check disk space'
        report prepare ok
        cat > "$work/upload.gz" || fail copy 'Cannot save the upload; check disk space'
        report copy ok
        if [ "$compressed" = 1 ]; then
          gzip -dc "$work/upload.gz" > "$stage/tecolot-sessiond" || fail unpack 'Cannot unpack the upload; check disk space'
        else
          mv "$work/upload.gz" "$stage/tecolot-sessiond" || fail unpack 'Cannot save the helper; check disk space'
        fi
        report unpack ok
        actual=$(hash_file "$stage/tecolot-sessiond") || fail hash 'No SHA-256 tool is available'
        [ "$actual" = "$expected" ] || fail hash 'The helper hash does not match'
        report hash ok
        chmod 700 "$stage/tecolot-sessiond" || fail chmod 'Cannot set the helper permissions'
        report chmod ok
        if ! "$stage/tecolot-sessiond" version --json >"$work/version.out" 2>"$work/version.err"; then
          error_text=$(cat "$work/version.err")
          case "$error_text" in
            *'Permission denied'*|*'permission denied'*) fail version 'The home directory does not allow programs to run (noexec)' ;;
            *) fail version 'Cannot run the helper; check noexec and the host architecture' ;;
          esac
        fi
        report version ok
        ensure_private "$base/bin" && ensure_private "$base/bin/$binary" || fail install 'The install directory is not safe'
        parent="$base/bin/$binary"
        destination="$parent/$release"
        lock="$parent/.install-$release"
        count=0
        while ! mkdir "$lock" 2>/dev/null; do
          count=$((count + 1))
          [ "$count" -lt 15 ] || fail install 'Another install did not finish'
          sleep 1
        done
        lock_owned=1
        if [ -e "$destination" ] || [ -L "$destination" ]; then
          private_dir "$destination" && [ ! -L "$destination/tecolot-sessiond" ] || fail install 'The installed helper directory is not safe'
          existing=$(hash_file "$destination/tecolot-sessiond") || fail install 'Cannot check the installed helper'
          [ "$existing" = "$expected" ] || fail install 'The installed helper hash does not match'
          "$destination/tecolot-sessiond" version --json >/dev/null 2>&1 || fail install 'Cannot run the installed helper'
        else
          mv "$stage" "$destination" || fail install 'Cannot install the helper; check disk space'
        fi
        report install ok
        printf '%s\n' "$expected" > "$work/sha256" || fail hash-file 'Cannot save the hash; check disk space'
        [ ! -d "$destination/sha256" ] || fail hash-file 'The installed hash file is not safe'
        mv -f "$work/sha256" "$destination/sha256" || fail hash-file 'Cannot install the hash file; check disk space'
        report hash-file ok
        rmdir "$lock" || fail cleanup 'Cannot remove the install lock'
        lock_owned=0
        rm -rf "$work" || fail cleanup 'Cannot remove the upload directory'
        report cleanup ok
        """#
    }
}
