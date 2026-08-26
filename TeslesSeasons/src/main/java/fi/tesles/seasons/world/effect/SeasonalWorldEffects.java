package fi.tesles.seasons.world.effect;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.sector.SeasonFrame;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The installed set of {@link SeasonalWorldEffect}s.
 *
 * <p>Registration order is preserved and is the order effects run in, so an effect that depends on
 * another having gone first can be registered after it. Registering the same id twice replaces the
 * earlier one, which is how a pack overrides a built-in effect rather than fighting it.
 */
public final class SeasonalWorldEffects {
   private static final Map<String, SeasonalWorldEffect> EFFECTS = new LinkedHashMap<>();
   private static volatile List<SeasonalWorldEffect> snapshot = List.of();

   private SeasonalWorldEffects() {
   }

   public static synchronized SeasonalWorldEffect register(SeasonalWorldEffect effect) {
      if (effect == null || effect.id() == null || effect.id().isBlank()) {
         throw new IllegalArgumentException("a world effect needs a non-blank id");
      }

      SeasonalWorldEffect previous = EFFECTS.put(effect.id(), effect);
      snapshot = List.copyOf(EFFECTS.values());
      if (previous == null) {
         TeslesSeasons.LOGGER.info("Seasonal world effect registered: {}", effect.id());
      } else {
         TeslesSeasons.LOGGER.info("Seasonal world effect replaced: {}", effect.id());
      }
      return previous;
   }

   public static synchronized void unregister(String id) {
      if (EFFECTS.remove(id) != null) {
         snapshot = List.copyOf(EFFECTS.values());
      }
   }

   /** All installed effects, in registration order. Safe to iterate from the server thread. */
   public static List<SeasonalWorldEffect> all() {
      return snapshot;
   }

   /**
    * The effects this frame actually needs, or an empty list.
    *
    * <p>Resolved once per chunk pass. The empty case is the common one for most of the year and
    * has to stay free of allocation, so it returns the shared empty list rather than a filtered
    * copy of nothing.
    */
   public static List<SeasonalWorldEffect> active(SeasonFrame frame) {
      List<SeasonalWorldEffect> installed = snapshot;
      if (installed.isEmpty()) {
         return List.of();
      }

      List<SeasonalWorldEffect> active = null;
      for (SeasonalWorldEffect effect : installed) {
         if (effect.appliesTo(frame)) {
            if (active == null) {
               active = new ArrayList<>(installed.size());
            }
            active.add(effect);
         }
      }
      return active == null ? List.of() : Collections.unmodifiableList(active);
   }
}
