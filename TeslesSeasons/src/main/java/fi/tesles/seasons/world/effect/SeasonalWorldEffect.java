package fi.tesles.seasons.world.effect;

import fi.tesles.seasons.sector.SeasonFrame;

/**
 * One seasonal behaviour of the world, as a module.
 *
 * <p>Snow, leaf fall and flora are built into the reconciler because they are the contract the
 * specification pins. Everything else a season might do to the world - lakes freezing, puddles,
 * frost on glass, ice thickening, mud in spring - belongs here: a class, a registration, and
 * nothing else in the mod has to change.
 *
 * <h2>What an effect must honour</h2>
 * <ul>
 *   <li><b>The frame is the target, never a delta.</b> An effect is told what the world should
 *       look like now and converges it there. It must not remember what season it was last time
 *       or count how far through a transition it has got; a player who logs in mid-winter must
 *       get the same world as one who watched it arrive.</li>
 *   <li><b>Decide by coordinate, not by chance.</b> Use
 *       {@link fi.tesles.seasons.world.system.SeasonCoordinateField} with a salt of your own.
 *       A {@code Random} makes the near world and the distant LOD disagree, and makes the effect
 *       flicker as chunks reload.</li>
 *   <li><b>Own what you place.</b> Only ever remove blocks you recorded through
 *       {@link SeasonalEffectContext#markOwned}. Everything else in the world belongs to a
 *       player, and seasonal cleanup that forgets this deletes builds.</li>
 *   <li><b>Stay inside the budget.</b> Every write goes through the context, which returns
 *       {@code false} when the tick's budget is spent. Return {@code false} straight away when it
 *       does; the column is visited again.</li>
 * </ul>
 */
public interface SeasonalWorldEffect {
   /**
    * Stable identifier, used as the key of this effect's ownership ledger.
    *
    * <p>It is written into chunk data, so changing it orphans everything the effect owns. Treat
    * it the way you would a block id.
    */
   String id();

   /**
    * Cheap test for whether this frame needs the effect at all.
    *
    * <p>Answered once per chunk pass rather than per column. An effect that says no here costs
    * nothing for the rest of the year, which is what keeps a summer afternoon cheap - so make it
    * a comparison against the frame, not a look at the world.
    */
   default boolean appliesTo(SeasonFrame frame) {
      return true;
   }

   /**
    * Converges one column toward the frame.
    *
    * @return {@code false} if the tick's budget ran out mid-column, so the column is retried
    */
   boolean applyToColumn(SeasonalEffectContext context);
}
