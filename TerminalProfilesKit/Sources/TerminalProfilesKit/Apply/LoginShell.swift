//
//  LoginShell.swift
//  TerminalProfilesKit
//
import Foundation

public enum LoginShell {
    /// The current user's login shell from the password database,
    /// falling back to /bin/bash
    public static var current: String {
        let bufsize = sysconf (_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else {
            return "/bin/bash"
        }
        let buffer = UnsafeMutablePointer<CChar>.allocate (capacity: bufsize)
        defer {
            buffer.deallocate ()
        }
        var pwd = passwd ()
        var result: UnsafeMutablePointer<passwd>? = nil

        if getpwuid_r (getuid (), &pwd, buffer, bufsize, &result) != 0 || result == nil {
            return "/bin/bash"
        }
        return String (cString: pwd.pw_shell)
    }

    /// The argv[0] login idiom for a shell path: "/bin/zsh" -> "-zsh"
    public static func loginArgZero (for shellPath: String) -> String {
        let name = (shellPath as NSString).lastPathComponent
        return "-" + name
    }
}
