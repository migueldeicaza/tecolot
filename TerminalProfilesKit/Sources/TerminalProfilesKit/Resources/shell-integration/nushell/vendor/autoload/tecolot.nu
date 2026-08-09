# Tecolot shell integration
export module tecolot {
  def has_feature [feature: string] {
    $feature in ($env.TECOLOT_SHELL_FEATURES | default "" | split row ',')
  }

  # Wrap `ssh` with `tecolot +ssh` and translate the shell-integration
  # feature flags into command options.
  @complete external
  export def --wrapped ssh [...args] {
    if not ((has_feature "ssh-env") or (has_feature "ssh-terminfo")) {
      ^ssh ...$args
      return
    }

    let tecolot = ($env.TECOLOT_BIN_DIR? | default "") | path join "tecolot"
    mut flags = []
    if not (has_feature "ssh-env") {
      $flags = ($flags ++ ["--forward-env=false"])
    }
    if not (has_feature "ssh-terminfo") {
      $flags = ($flags ++ ["--terminfo=false"])
    }
    ^$tecolot "+ssh" ...$flags "--" ...$args
  }

  # Wrap `sudo` to preserve Tecolot's TERMINFO environment variable
  @complete external
  export def --wrapped sudo [...args] {
    mut sudo_args = $args

    if (has_feature "sudo") {
      # Extract just the sudo options (before the command)
      let sudo_options = (
        $args | take until {|arg|
          not (($arg | str starts-with "-") or ($arg | str contains "="))
        }
      )

      # Prepend TERMINFO preservation flag if not using sudoedit
      if (not ("-e" in $sudo_options or "--edit" in $sudo_options)) {
        $sudo_args = ($args | prepend "--preserve-env=TERMINFO")
      }
    }

    ^sudo ...$sudo_args
  }
}

# Clean up XDG_DATA_DIRS by removing TECOLOT_SHELL_INTEGRATION_XDG_DIR
if 'TECOLOT_SHELL_INTEGRATION_XDG_DIR' in $env {
  if 'XDG_DATA_DIRS' in $env {
    $env.XDG_DATA_DIRS = ($env.XDG_DATA_DIRS | str replace $"($env.TECOLOT_SHELL_INTEGRATION_XDG_DIR):" "")
  }
  hide-env TECOLOT_SHELL_INTEGRATION_XDG_DIR
}
