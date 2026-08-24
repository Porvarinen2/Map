package fi.tesles.seasons.sector;

import fi.tesles.seasons.api.SeasonSnapshot;

/**
 * A season module: a pure formula from a clock snapshot to an absolute {@link SeasonFrame}.
 *
 * <p>Implementations must not touch the world, the scheduler or mod compatibility. They are
 * pure functions so the 96-checkpoint contract suite and the phase-boundary continuity suite
 * can evaluate them without a Minecraft instance.
 *
 * <p><b>Continuity contract.</b> The cycle order is SUMMER -> AUTUMN -> WINTER -> SPRING ->
 * SUMMER. Every continuous channel must leave a phase at exactly the value the next phase
 * enters with, at all 12 boundaries. {@code SeasonContinuityTest} enforces this.
 */
public interface SeasonSector {
   SeasonFrame frame(SeasonSnapshot var1);

   static float clamp(float x) {
      return Math.max(0.0F, Math.min(1.0F, x));
   }
}
