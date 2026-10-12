//
// main.swift
// tecolot-sessiond
//
// The session helper that Tecolot embeds next to its executable. It runs one
// persistent terminal session per process (see Packages/TecolotSession).
//

import Foundation
import TecolotSessionDaemon

// Inside the app bundle, Bundle.main is the app, so the helper reports the
// app's version as its build.
if let info = Bundle.main.infoDictionary,
   let version = info["CFBundleShortVersionString"] as? String {
    let build = info["CFBundleVersion"] as? String ?? "0"
    SessionDaemonCommand.build = "\(version) (\(build))"
}
SessionDaemonCommand.main()
