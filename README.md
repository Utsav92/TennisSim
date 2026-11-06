# TennisSim

A native 3D tennis game for Apple Silicon (macOS) with an iOS target. Swift + C++ simulation core, Metal 4 + MetalFX rendering,
Blender-authored assets.

## Requirements
macOS 26+ on Apple Silicon, Xcode 27 (Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`), Blender 5 (only to regenerate assets).

## Build & run
```
python3 gen_pbxproj.py            # regenerate TennisSim.xcodeproj after adding/removing source files
xcodebuild -project TennisSim.xcodeproj -scheme TennisSim -configuration Release -derivedDataPath build build
open build/Build/Products/Release/TennisSim.app

# iOS (simulator / device; signing disabled for the build check)
xcodebuild -project TennisSim.xcodeproj -scheme TennisSim-iOS -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios CODE_SIGNING_ALLOWED=NO build
```

## Controls
| | macOS | Controller | iOS |
|---|---|---|---|
| Move | WASD / arrows | left stick | drag on left half |
| Toss / swing | Space | A | SWING button |
| New match | R | X | menu |
| Camera | C | – | menu |
| Pause + settings | Esc | Menu button | ☰ |

Serve: swing to toss, swing again to hit. Swing type is chosen automatically: overhead for serves and high balls, backhand when the
ball is on your left, otherwise forehand. Hold a direction while swinging to steer the shot.

## Rules implemented
Points 0/15/30/40/deuce/advantage, games, one set to 6 (win by 2) with a 7-point tiebreak at 6–6, two serves with fault/double fault,
diagonal service box, net-cord lets, singles lines, second-bounce winners. Not implemented: end changes (the human always plays the
near end so the camera/controls stay fixed), doubles, challenges.

## Architecture (`TennisSim/`)
- `Sim/` C++ ball physics core (`BallSim.cpp`): gravity, drag, Magnus/spin, bounce, net and net cord. C interface, called from Swift.
- `Game/` pure-Swift game logic (no rendering): `GameState` (rules, scoring, crowd excitement), `Player`, `AIController`, `Animation`
  (joint rig, clips, blending).
- `Rendering/` `Renderer` (frame data, classic path), `Metal4Backend` (Metal 4 + MetalFX frame graph), `Shaders.metal`, `SceneBuilder`,
  `Stadium`/crowd placement, scoreboard texture, OBJ loader.
- `Input/` keyboard, controller, touch. `App/` macOS app, settings, CLI tools. `iOS/` UIKit front end. `Assets/Models/` OBJ meshes.
- `Tools/blender/make_assets.py` regenerates the player, racket and spectator meshes:
  `/Applications/Blender.app/Contents/MacOS/Blender --background --python Tools/blender/make_assets.py -- TennisSim/Assets/Models`

## Rendering
Metal 4 path (default where supported): sun shadow map → HDR scene pass with motion vectors → MetalFX temporal AA + upscaling
(render scale 100/75/50 %, settings menu) → bloom → tone-mapped composite. ~4,500 GPU-instanced spectators animate in the vertex
shader. The classic Metal path (LDR, 4× MSAA) is the fallback (iOS Simulator has no Metal 4; force with `TS_METAL3=1`).

## Verification tools (run the built app binary)
`--selftest` headless physics/rules/animation/AI tests · `--snapshot out.png` · `--poses out.png` · `--crowd out.png` ·
`--motion out.png` · `--bench N` (GPU/CPU times, both backends) · `--compare-backends`.
Use `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1` to run any of them under Metal validation.
