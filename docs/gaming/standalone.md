# Standalone offline launchers

The xyz gaming module declares Spider-Man Remastered (regular and couch),
Spider-Man 2, and Cyberpunk 2077. Each reuses its installed prefix and pins
GE-Proton11-3. Artwork is fetched by content hash.

All four entries explicitly display Offline and set `networkAccess = false`.
The UMU runner starts in a new user/network namespace before Proton runs;
namespace failure stops startup instead of falling back to online mode. Runtime
files must already be cached. The normal prefix guard and user-service lifetime
prevent duplicate primary launches. Battle.net and Heroes Profile retain their
online configuration, including Heroes of the Storm through Battle.net.

Heroic's Play button is an independent launch path and does not inherit the
network block. Use the Offline application-menu entries for isolated play.

## Cyberpunk compatibility

Cyberpunk requires `WINEDLLOVERRIDES=icuuc,icuin=n` to load the game's bundled
ICU libraries. Those libraries export ICU 65 functions that Wine's built-in
libraries do not provide. This override is scoped to Cyberpunk only.

## Qualification

- Remastered's direct gameplay, input/audio, save loading, exit, relaunch, and
  couch launch behavior were accepted by the user. Its offline process was
  subsequently verified in a separate network namespace without routes.
- Spider-Man 2 was accepted by the user through the local offline launcher.
- Cyberpunk reached a game window after the ICU override and the user confirmed
  it working. Extended gameplay and quit/relaunch acceptance remain pending.
- The Nix declarations retain the qualified paths, Proton release, network
  restriction, and compatibility settings. Spider-Man 2 and Cyberpunk adopt
  the existing service-managed lifecycle; those generated services require
  separate runtime acceptance when activated.
- Steam Input and remote streaming/controller behavior remain separate tests.

The declarative entries describe launching installed games, not distributing
or installing game data. More games can inform a future installation workflow;
these examples do not establish universal installer requirements.
