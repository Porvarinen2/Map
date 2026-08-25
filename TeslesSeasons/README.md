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
| `VoxySnowParityTest` | Physical, LOD-mesh and shader snow targets agree with zero mismatches, and stay identical for a whole revision. |
| `VoxyShaderPipelineTest` | The real GLSL injection chain, run against Voxy 0.2.18-beta's actual shaders: anchors still match, every function is defined once, every uniform is declared, and patching is idempotent. |
| `NeutralPersistenceTest` | Seasonal changes are recognised by the same field the server decided with, so they never reach Voxy's LOD database. |
| `TallPlantAtomicityTest` | Both halves of a double-height plant always reach the same verdict. |
| `SeasonRevisionChurnTest` | Bounds how often the world is told to redo itself, sampled at the real 30-second clock rate. |
| `verifyModWiring` | Every mixin is registered, every entrypoint resolves, no `ClientModInitializer` is orphaned. |
| `verifyMixinTargets` | Every `@Mixin` target class and injected method descriptor resolves against real bytecode, and no mixin targets the mod's own code. |

The two verification tasks exist because both failure modes have actually shipped
here. 0.7.0 carried 15 mixins that no config referenced and a
`ClientModInitializer` that was not an entrypoint — the entire Voxy seasonal
projection, silently inert. It also carried mixins aimed at methods that had been
renamed away, which would have killed the game at startup had they been
registered. Neither is visible by reading; both now fail the build.

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
- **Targets are a function of the revision.** Channels are quantised at the point
  of target selection, so "same revision" means "identical world targets" for the
  server, the LOD projector and the shader alike.
- **One logical plant, one decision.** Double-height plants resolve their
  membership at the lower half's coordinate; the field includes Y, so per-block
  evaluation would split them.
- **No mixin targets our own code.** If behaviour belongs in a class, it lives in
  that class. Runtime self-patching hides logic from readers and from tests.
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
