# gd-noclip

Tweak (.dylib) for Geometry Dash 2.205 (arm64, iOS 14+): noclip with an in-game
menu styled after Ascent.

Build: GitHub Actions macOS runner, artifact `Noclip-dylib`.

The dylib is injected into the decrypted `GeometryJump` binary
(`LC_LOAD_DYLIB @executable_path/Noclip.dylib`) and the IPA is repacked for
TrollStore.

Hook: `PlayLayer::destroyPlayer(PlayerObject*, GameObject*)` at file offset
`0x120084` (slot 159 of the PlayLayer vtable at `0x79b0a0`). When noclip is on,
the first 16 bytes are replaced with a branch to a C++ no-op; when off, the
original bytes are restored.

No game assets or binaries are stored in this repository.
