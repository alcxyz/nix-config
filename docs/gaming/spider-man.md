# Spider-Man Remastered direct launcher

The [game module](../../users/alc/linux/xyz/gaming/spider-man.nix) adds an
application through the existing UMU interface. This is a second concrete
launcher alongside Battle.net, not a general installation workflow.

## Existing installation

The launcher reuses the working Heroic installation and prefix in place. It
does not run an installer, move game files, alter saves, or change Heroic's entry.
The prefix has `pfx` pointing to its own root; the existing UMU prefix check
accepts this layout. Paths contain spaces and the executable path contains an
apostrophe, so the generated shell scripts must retain their argument quoting.

GE-Proton11-3 is pinned to match the working Heroic release. `PROTON_USE_XALIA=0`
preserves the saved game setting. Other game-specific overrides are not assumed
from Battle.net. GameMode is not requested while no host GameMode service is
available, consistent with the existing direct launchers.

## Qualification

- The installed executable and prefix pass direct-launch preflight.
- The generated runner and starter build, and the UMU shell checks cover all
  declared applications, including this one.
- The direct launcher opens the game. A repeated launch retains the same
  service process, and preflight refuses another primary process in the prefix.
- On 2026-09-14 the user confirmed existing-save loading, gameplay, input/audio,
  normal exit, and relaunch through the direct QA entry. Steam/controller
  integration is still a separate check.

Only one launcher may own this prefix at a time. Quit the game and let its
runtime exit before switching between Heroic and the direct entry.

## Couch launcher

The separate `Spider-Man Remastered (Couch, Offline)` entry passes `-nolauncher` to skip
the game's settings launcher. The regular entry retains the settings launcher.
Both share the same installation, prefix, Proton release, and saves, so the
same single-instance restriction applies.

The user accepted the couch launch behavior after testing. The regular and
couch entries now use their canonical names with explicit Offline labels and without QA suffixes. Remote
controller integration remains a separate acceptance step.

## Network access

Both entries set `networkAccess = false`. The entire UMU runtime starts inside
an isolated user/network namespace, retaining the calling user's UID. Failure
to create the namespace prevents launch; there is no online fallback. Runtime
updates are disabled and existing cached runtime files are required.

This affects these direct launchers only. Heroic launches bypass this policy.
Battle.net and Heroes Profile retain network access, including Heroes of the
Storm launched by Battle.net. Companion launches into offline prefixes are
unsupported. Gameplay was qualified before adding network isolation; offline
gameplay acceptance must be checked separately. The promoted regular entry was
launched successfully and its game process verified in a separate network
namespace with no routes.

## Steam follow-up

Steam Input and controller behavior are a separate acceptance step. The desktop
launcher starts a user service; adding that starter to Steam does not establish
that Steam will track the game or apply its controller configuration correctly.
Verify the launch integration and controller in practice before documenting a
recommended Steam shortcut. The current change does not modify Steam shortcuts.

Further games can use this module as an example, but their installed paths,
Proton release, and compatibility requirements must be checked independently.
