# Tecolot shell integration

Tecolot loads this integration automatically for interactive Zsh, Fish,
Nushell, Elvish, and supported Bash sessions. The scripts report prompt and
command boundaries with OSC 133. They also report the current directory with
OSC 7 and can update the terminal title and cursor.

The Zsh and Bash directory reports remove control characters from the hostname
and path. Zsh also prints backslashes as text. This prevents directory names
from adding escape sequences to an OSC 7 report. These checks follow
[Ghostty's fix for GHSA-2r63-vmw6-3m3c](https://github.com/ghostty-org/ghostty/pull/14859).

Every child process receives `TECOLOT_RESOURCES_DIR`. Users can use this
variable to load the bundled scripts manually or to locate related files.

## Bash

Add this code at the start of `.bashrc` when automatic injection is not
available. The `/bin/bash` version from macOS needs manual injection.

```bash
if [ -n "${TECOLOT_RESOURCES_DIR}" ]; then
    builtin source "${TECOLOT_RESOURCES_DIR}/shell-integration/bash/tecolot.bash"
fi
```

## Zsh

```zsh
if [[ -n $TECOLOT_RESOURCES_DIR ]]; then
    source "$TECOLOT_RESOURCES_DIR/shell-integration/zsh/tecolot-integration"
fi
```

Zsh 5.1 or later is required.

## Nushell

```nushell
source $TECOLOT_RESOURCES_DIR/shell-integration/nushell/vendor/autoload/tecolot.nu
use tecolot *
```

## Elvish

Tecolot adds the shell-integration directory to `XDG_DATA_DIRS`. Add this code
to the Elvish configuration to load the module automatically:

```elvish
if (eq $E:TERM_PROGRAM "tecolot") {
  try { use tecolot-integration } catch { }
}
```

## Source and licenses

These scripts are adapted from Ghostty's shell integration. The Bash and Zsh
files that contain GPL notices remain under GPLv3. `bash-preexec.sh` keeps its
upstream license and attribution in the file. The bundled `LICENSE` contains
the Tecolot MIT license and the complete Ghostty MIT license text.
