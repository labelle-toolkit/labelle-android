# labelle-android

Android platform package for the Labelle toolkit.

## Status

Repository scaffold only. Runtime extraction, packaging, and provider commands are not implemented or released yet. Do not add this repository as a working game dependency until the first usable release.

## Planned responsibilities

- Shared Android services: intent extras, data-directory access, immersive mode, display density, and APK asset access.
- Shared lifecycle handling where appropriate, preserving backend-owned GPU/context integration and sokol's app-shell requirements.
- One manifest, asset-staging, native-symbol, and APK packaging implementation, shared by direct builds and Gradle integration.
- Package-provided Android commands and target hooks through the CLI's generic provider contract.

The existing `labelle-android-gamepad` remains a separate package unless its ownership is changed explicitly. Backend renderer code stays in its backend repository.

## Implementation references

- [Shared runtime extraction: bgfx #149](https://github.com/labelle-toolkit/labelle-bgfx/issues/149)
- [Packaging consolidation: CLI #405](https://github.com/labelle-toolkit/labelle-cli/issues/405)
- [Provider architecture: CLI #406](https://github.com/labelle-toolkit/labelle-cli/issues/406)
- [Contract decisions before implementation: CLI #411](https://github.com/labelle-toolkit/labelle-cli/issues/411)
- [APK-loaded assets: assembler #759](https://github.com/labelle-toolkit/labelle-assembler/issues/759)

Migration is breaking: consumers explicitly adopt the package and update configuration. No compatibility shims or implicit provider injection. Introduce the package manifest after the contract decisions are settled.

Device validation must cover bgfx and sokol cold launch, background/resume, rotation, and asset access; cross-compilation alone is not runtime acceptance.
