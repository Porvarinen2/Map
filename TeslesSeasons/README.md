# TeslesSeasons — Minecraft Fabric 26.2

Real-calendar seasons with physical world mutation (snow, leaves, flora) and a
season-neutral Voxy LOD integration.

## Building

```bash
./gradlew build
```

The mod jar lands in `build/libs/teslesseasons-1.0.0.jar`.

Requirements:

| Component | Version | Notes |
|---|---|---|
| JDK | **25** | Minecraft 26.2 requires Java 25. |
| Gradle | 9.5.1 | Provided by the wrapper — just use `./gradlew`. |
| Fabric Loom | 1.17.19 | Resolved automatically. |
| Minecraft | 26.2 | Downloaded automatically. |

If `./gradlew` picks the wrong JDK:

```bash
JAVA_HOME=/path/to/jdk-25 ./gradlew build
```

### Why there is an `identity-mappings` jar

Minecraft 26.2 ships **deobfuscated**. Mojang publishes no mappings artifact for
it, and Fabric's intermediary for 26.2 is the empty `0.0.0` set. Loom still
requires *a* mappings dependency, so `libs/identity-mappings-26.2.jar` supplies a
tiny-v2 file with an `official -> named` header and no entries: every name maps
to itself. It is generated from `build-support/identity-mappings/` and is the
reason `loom.useIntermediateMappings = false` is set.

### Integration jars

`libs/` also holds the exact third-party builds this mod is compiled against
(Voxy 0.2.18-beta, VoxyServer 1.2.4, Dynamic Trees, TeslesWorldGeneration). They
are `compileOnly`. Every mixin target in this project was verified against these
exact binaries — replacing them with different builds may invalidate a target.

## Verification

`./gradlew build` runs the contract suites before producing the jar:

| Suite | What it proves |
|---|---|
| `SeasonCheckpointContractTest` | 96/96 phase checkpoints (12 phases × 8 progress values) match the canonical contracts. |
| `SeasonContinuityTest` | 168 boundary checks: 14 continuous channels × 12 phase boundaries, exact match. |
| `SeasonFieldStatisticsTest` | The coordinate field is uniform, pure, and its per-channel salts are independent. |
| `VoxySnowParityTest` | Physical, LOD-mesh and shader snow targets agree with zero mismatches; snow layer states and phase statistics are legal. |
| `verifyModWiring` | Every mixin is registered, every entrypoint resolves, no `ClientModInitializer` is orphaned. |

`verifyModWiring` exists because the 0.7.0 release shipped 15 mixins that no
config referenced and a `ClientModInitializer` that was not an entrypoint. Both
fail **silently** at runtime. They now fail the build instead.

## Architecture

One authority, many projectors:

```
RealCalendarSeasonClock / SeasonDebugController
        |
        v
   SeasonDirector  ──── mints a revision only when targets change
        |
        v
  immutable SeasonFrame  (absolute targets, never deltas)
        |
        ├─ SnowSystem / LeafSystem / FloraSystem   physical blocks
        ├─ SeasonalWorldReconciler                 chunk canonicalisation
        ├─ VoxySeasonMeshProjectionMixin           LOD geometry
        ├─ VoxyShaderUniformMixin                  the one uniform binder
        └─ VoxyNeutralSnapshot                     season-neutral ingest
```

Rules that hold this together, and that regressions historically broke:

- **One season truth.** `SeasonDirector` is the only thing that interprets the
  calendar. Nothing else derives, caches or reinterprets a season.
- **Percent means world, not progress.** A target of 25% means a quarter of the
  world, selected by a deterministic coordinate field — never "25% of the queue
  has been processed".
- **One coordinate field.** `SeasonCoordinateField` is thresholded identically by
  the physical projector, the LOD mesh projector and the GLSL shader. This is
  what makes near and distant terrain agree without storing any season history.
- **Voxy persistence is season-neutral.** Season is applied when a section is
  meshed, not when it is stored, so LOD data never carries a season and cannot
  go stale. `VoxySeasonRemeshScheduler` stamps each section with the revision it
  was meshed at, and `VoxySeasonGeometryCacheBypassMixin` refuses any cached mesh
  built under an older revision.
- **Ownership before deletion.** Only snow recorded in a chunk's owned-snow
  ledger is ever removed. Player-placed snow is never adopted or deleted.
- **Absent means absent.** A leaf the frame removes is AIR, never an invisible
  collision box.
- **Grass identity is never changed.** Winter comes from snow layers and tint,
  never from swapping `grass_block`.

## Configuration

`config/teslesseasons.json` is written on first run. Cosmetic options are yours;
the values the season contract depends on are re-pinned on every load by
`TeslesSeasonsConfig.enforceCanonicalTargets()` — see that method for why.

## Commands

```
/teslesseasons status
/teslesseasons timelapse <seconds>
/teslesseasons timelapseweather <on|off|status>
```
