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
| `FloraClassificationTest` | Classification against the **real** Minecraft block registry: flowers, plants, mushrooms, berries, and everything that must never be touched. |
| `FloraChannelTest` | Every flora category tracks its own frame channel and its own field salt. |
| `WildBerryClassificationTest` | Wild berry bushes reach the berry channel whatever block class they extend, and cultivated crops never do. |
| `GroundCoverFallbackTest` | Melting snow always has a placeholder to fall back on, including on slab terrain. |
| `SnowSupportTest` | Snow rests on ground and never on water, ice or foliage — the same verdict on the server and in the LOD projector. |
| `ColumnSweepTest` | A chunk's column sweep is a true permutation, so no column can starve however fast the calendar moves. |
| `ModularityTest` | Seasons and world effects can be replaced, keep their order, are skipped when inactive, and cannot register without an id. |
| `SeasonNeutralityTest` | Only writes that heal the world toward neutral reach the LOD store, so a store built in any season converges on the neutral one. |
| `VoxySnowParityTest` (melt) | Winter Outgoing keeps its canonical footprint exactly, and no column ever drops from 2/8 or deeper straight to bare ground. |
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
   SeasonRegistry ──── one SeasonSector per season, replaceable
        |
        v
   SeasonDirector  ──── mints a revision only when targets change
        |
        v
  immutable SeasonFrame  (absolute targets, never deltas)
        |
        ├─ SnowSystem / LeafSystem / FloraSystem   physical blocks
        ├─ SeasonalWorldEffects                    pluggable behaviours
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
- **Voxy persistence is season-neutral, and heals.** Season is applied when a
  section is meshed, not when it is stored, so LOD data never carries a season
  and cannot go stale. Suppression is *directional*: writes that take the world
  away from neutral are kept out of the LOD store, and writes that bring it back
  are deliberately let through. Blocking both looks safer and is not — it freezes
  each region's LOD at whatever season it was first built in. `VoxySeasonRemeshScheduler` stamps each section with the revision it
  was meshed at, and `VoxySeasonGeometryCacheBypassMixin` refuses any cached mesh
  built under an older revision.
- **Ownership before deletion.** Only snow recorded in a chunk's owned-snow
  ledger is ever removed. Player-placed snow is never adopted or deleted.
- **Targets are a function of the revision.** Channels are quantised at the point
  of target selection, so "same revision" means "identical world targets" for the
  server, the LOD projector and the shader alike.
- **One registry, resolved once.** Every installed block is classified at startup into an
  identity table. Keyword heuristics run over the real registry to build that table and
  never again; they are not the production lookup, and the result is logged.
- **Identity decides category, not superclass.** What a block *is* comes from its
  registry id. A wild berry bush is berry flora whether it extends a bush block or
  a crop block; classifying by Java type instead put eight of nine berry blocks in
  the wrong channel.
- **One logical plant, one decision.** Double-height plants resolve their
  membership at the lower half's coordinate; the field includes Y, so per-block
  evaluation would split them.
- **No mixin targets our own code.** If behaviour belongs in a class, it lives in
  that class. Runtime self-patching hides logic from readers and from tests.
- **Absent means absent.** A leaf the frame removes is AIR, never an invisible
  collision box.
- **Snow melts a layer at a time.** The canonical mapping brings footprint and
  depth down together; how one column gets from its depth to zero is left to
  `SnowSystem`, which gives each layer its own slice of retreating coverage. A
  column inside the footprint always keeps at least its last layer, so coverage
  stays exactly on spec and the final step a player sees is 1/8 giving way to
  ground.
- **Confirming nothing to do must cost nothing.** Most of the year every
  retention is full and there is no snow. A column sweep can then only confirm
  the world is already correct, and it does so without touching it.
- **Grass identity is never changed.** Winter comes from snow layers and tint,
  never from swapping `grass_block`.
- **A canopy is not the ground.** Anything looking for a column's surface ignores
  foliage, exactly as the server's `MOTION_BLOCKING_NO_LEAVES` heightmap does.
  A search that stops at the first non-air voxel finds the treetop in every
  forested column.
- **Sweeps are never restarted by the clock.** A chunk's column cursor advances
  continuously and wraps; tying it to the season revision let a fast calendar
  reset it before it ever reached the far side of the chunk.

## Diagnostics

```
/teslesseasons diagnostic year [seconds]   # default 600
```

Runs a full simulated year and writes a ZIP holding per-second season channels
(`timeline.csv`), ten paired `*-state.txt` / `*-world-sample.csv` captures, screenshots,
Voxy category and shader counters, the relevant configs and the log tail. Upload it as-is
when reporting a visual problem — the world sample records the actual surface block of a
fixed grid of columns, so a claim about what the world looks like can be checked rather
than guessed at.

The capture schedule keys on season *channels*, not on wall-clock time, so each checkpoint
lands at the same point of the year on any timelapse speed.

## Extending it

Two things are pluggable: what a season *is*, and what a season *does to the world*.

### Replacing a season

A season is a pure function from a clock snapshot to a `SeasonFrame` of absolute
targets. Write one, register it, and nothing else changes:

```java
SeasonRegistry.register(Season.WINTER, new HarshWinterSector());
```

`SeasonDirector` reads the registry rather than naming the four built-ins, so
there is no switch to edit. A replacement is held to the same contract as the
original: the checkpoint and continuity suites run against **whatever is
registered**, so one that breaks phase continuity fails the build, not the world.

### Adding a world behaviour

Snow, leaf fall and flora are built in because the specification pins them.
Anything else — lakes freezing, puddles, frost on glass, mud in spring — is a
`SeasonalWorldEffect`: one class, one registration.

```java
public final class PuddleEffect implements SeasonalWorldEffect {
   public String id() { return "mymod:puddles"; }

   public boolean appliesTo(SeasonFrame frame) {
      return frame.springFreshness() > 0.0F;      // free for the rest of the year
   }

   public boolean applyToColumn(SeasonalEffectContext ctx) {
      boolean wet = SeasonCoordinateField.effect01(ctx.x(), ctx.z(), ctx.seed(), MY_SALT)
                  < ctx.frame().springFreshness() * 0.3F;
      for (BlockPos owned : ctx.ownedInColumn()) {
         if (!wet && !ctx.restore(owned, Blocks.DIRT.defaultBlockState())) return false;
      }
      return !wet || ctx.place(ctx.surface(), Blocks.MUD.defaultBlockState());
   }
}
```

```java
SeasonalWorldEffects.register(new PuddleEffect());
```

`WaterFreezeEffect` is the shipped worked example — the whole of winter lake ice
in one file. Enable it with `seasonalWaterFreezing` in the config; it is off by
default because turning it on changes what an existing world looks like.

**What the context gives you, so you cannot get it wrong:**

| You call | You get |
|---|---|
| `ctx.frame()` | absolute targets — never ask how far through a transition you are |
| `ctx.seed()` + `SeasonCoordinateField.effect01(..., yourSalt)` | the same deterministic field the snow and the distant LOD use |
| `ctx.surface()` | the ground, ignoring foliage — the same position the snow pass calls the surface |
| `ctx.place(pos, state)` | a budgeted write, recorded as **yours** |
| `ctx.restore(pos, state)` | undoes one of *your* placements, and silently declines anything else |
| `ctx.ownedInColumn()` | what you own here, so you can take it back |

Three properties come free from using them, and are the reason to:

- **Player builds are safe.** `restore` only touches what `place` recorded. A
  thaw cannot eat ice a player put there.
- **Distant terrain agrees.** `place` is held out of Voxy's LOD store and
  `restore` is let through, so the store keeps converging on the neutral world
  without your effect knowing that store exists.
- **The tick survives.** Every write is budgeted; return `false` when one does
  and the column is picked up again.

Give each effect its own salt. Two sharing one select the same coordinates, and
the correlation shows up in game as the two appearing and vanishing in exactly
the same patches.

An effect that throws is logged once and skipped for that column. It cannot take
the season system down with it.

## Configuration

`config/teslesseasons.json` is written on first run. Cosmetic options are yours;
the values the season contract depends on are re-pinned on every load by
`TeslesSeasonsConfig.enforceCanonicalTargets()` — see that method for why.

## Commands

```
/teslesseasons status
/teslesseasons timelapse <seconds>
/teslesseasons timelapseweather <on|off|status>
/teslesseasons diagnostic capture
/teslesseasons diagnostic year [seconds]
```
