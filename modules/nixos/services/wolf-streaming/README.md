# Wolf streaming module

`default.nix` composes the application catalog, images, runtime helpers, and
host services. `options.nix` declares the public module interface; its image
defaults and shared input defaults are supplied explicitly by the composition
module. `apps.nix` owns public and protected application definitions,
generated catalogs, and their reconciliation commands. `images.nix` owns
pinned sources, patches, image tags, and browser build contexts, parameterized
by packages and browser options.

`browser-image/` contains the browser image and desktop/input helpers.
`wolf-image/` contains coordinator image patches. `nvrtc-runtime.nix` packages
its runtime libraries, while `worker-runtime.nix` supplies node-local worker
assets. The Python helpers beside these modules reconcile application/profile
state and manage cooperative sessions.

Keep input mirroring, native button delivery, and process startup ordering as
separate responsibilities. Run `just input` for browser input or lifecycle
changes; its pointer and primary-click checks form one acceptance contract.
