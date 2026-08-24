package fi.tesles.seasons.fix064.client;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.sector.SeasonDirector;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import me.cortex.voxy.client.core.rendering.SectionUpdateRouter;
import me.cortex.voxy.common.world.WorldEngine;
import me.cortex.voxy.common.world.WorldSection;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.Minecraft;

/**
 * Drives Voxy LOD sections back to the current season and guarantees that no LOD geometry
 * built under an older season can stay on screen.
 *
 * <h2>The guarantee</h2>
 * Every watched section carries the {@link SeasonDirector#revision()} it was last meshed at.
 * When the director mints a new revision, every watched section is stale by definition, and
 * a stale section is both (a) re-queued for remesh here and (b) refused if Voxy tries to
 * serve it from its geometry cache. There is no path by which a section rendered under
 * revision N can still be displayed at revision N+1 - travelling far enough to unload and
 * reload a section does not reintroduce old seasons, because the persisted LOD data is
 * season-neutral and season is applied at mesh time.
 *
 * <h2>Convergence order</h2>
 * Work is ordered by distance from the player, nearest first. The previous implementation
 * shuffled the watched set randomly and processed one section per tick, so a large view
 * distance took many minutes to converge and the sections the player was actually looking at
 * could be processed last. That is what "old season chunks in the distance" looked like.
 */
public final class VoxySeasonRemeshScheduler implements ClientModInitializer {
   /** Highest LOD level that carries projected seasonal geometry. */
   private static final int MAX_STRUCTURAL_LOD = 2;

   /**
    * Sections re-queued per client tick. At 20 tps this converges ~5000 sections in about
    * four seconds while staying well inside Voxy's own mesh worker budget.
    */
   private static final int SEASONAL_BUDGET_PER_TICK = 64;

   /** Neutral (near-field handoff) rebuilds are more urgent and cheaper; allow more. */
   private static final int NEUTRAL_BUDGET_PER_TICK = 32;

   /** Re-sort the work queue once the player has moved this far (squared blocks). */
   private static final double RESORT_DISTANCE_SQ = 64.0 * 64.0;

   private static final Set<Long> WATCHED = ConcurrentHashMap.newKeySet();
   private static final Set<Long> PROTECTED = ConcurrentHashMap.newKeySet();
   private static final ConcurrentLinkedQueue<Long> URGENT_NEUTRAL = new ConcurrentLinkedQueue<>();
   private static final Set<Long> URGENT_NEUTRAL_SET = ConcurrentHashMap.newKeySet();

   /**
    * Geometry key each section was last meshed against. Written from Voxy mesh worker threads,
    * read from the client thread, so it must stay concurrent.
    *
    * <p>This tracks {@code SeasonFrame.geometryKey()} rather than the frame revision. Colour
    * changes reach Voxy through shader uniforms and need no rebuild, so keying on the full
    * revision rebuilt the entire LOD set every time the calendar advanced at all.
    */
   private static final ConcurrentHashMap<Long, Long> PROJECTED_GEOMETRY = new ConcurrentHashMap<>();

   private static volatile SectionUpdateRouter router;
   private static volatile double playerX;
   private static volatile double playerZ;
   private static volatile int handoffRadiusBlocks = 256;
   private static volatile boolean havePlayerPosition;

   private static List<Long> pending = List.of();
   private static int pendingIndex;
   private static long queuedGeometryKey = Long.MIN_VALUE;
   private static double lastSortX = Double.NaN;
   private static double lastSortZ = Double.NaN;
   private static int lastProtectionRadius = -1;

   @Override
   public void onInitializeClient() {
      if (!FabricLoader.getInstance().isModLoaded("voxy")) {
         return;
      }
      ClientTickEvents.END_CLIENT_TICK.register(VoxySeasonRemeshScheduler::tick);
      TeslesSeasons.LOGGER.info("Voxy seasonal remesh scheduler active; LOD 0-{} projected from the current SeasonFrame.",
         MAX_STRUCTURAL_LOD);
   }

   // ---------------------------------------------------------------- watch bookkeeping

   public static void watch(SectionUpdateRouter updateRouter, long position) {
      router = updateRouter;
      if (!isStructural(position)) {
         return;
      }
      if (WATCHED.add(position)) {
         if (isHandoffUnsafe(position)) {
            PROTECTED.add(position);
            enqueueUrgentNeutral(position);
         } else {
            // A newly watched section has never been projected: force it into the queue.
            invalidateQueue();
         }
      }
   }

   public static void unwatch(long position) {
      if (!isStructural(position)) {
         return;
      }
      WATCHED.remove(position);
      PROTECTED.remove(position);
      URGENT_NEUTRAL_SET.remove(position);
      PROJECTED_GEOMETRY.remove(position);
   }

   // ------------------------------------------------------------- staleness contract

   /** Records that {@code key} has been meshed against {@code geometryKey}. */
   public static void markProjected(long key, long geometryKey) {
      // Only LOD 0-2 carry projected geometry and only those are consulted by the cache
      // bypass; tracking anything else would grow without ever being cleaned up.
      if (isStructural(key)) {
         PROJECTED_GEOMETRY.put(key, geometryKey);
      }
   }

   /**
    * True when the geometry cached for {@code key} was built against different snow targets
    * than {@code currentGeometryKey}, and must therefore not be shown.
    */
   public static boolean isStale(long key, long currentGeometryKey) {
      Long built = PROJECTED_GEOMETRY.get(key);
      return built == null || built != currentGeometryKey;
   }

   // -------------------------------------------------------------- near/far handoff

   public static boolean isHandoffUnsafe(WorldSection section) {
      return section != null && isHandoffUnsafe(section.key);
   }

   /**
    * True for sections close enough that vanilla is already rendering the real blocks. Season
    * must not be projected onto those, or the seam between real terrain and LOD shows the
    * effect applied twice.
    */
   public static boolean isHandoffUnsafe(long position) {
      if (!havePlayerPosition) {
         return false;
      }
      int scale = 1 << Math.max(0, WorldEngine.getLevel(position));
      double cx = (((long) WorldEngine.getX(position) << 5) + 16.0) * scale;
      double cz = (((long) WorldEngine.getZ(position) << 5) + 16.0) * scale;
      double dx = cx - playerX;
      double dz = cz - playerZ;
      double radius = handoffRadiusBlocks + 16.0 * scale;
      return dx * dx + dz * dz <= radius * radius;
   }

   // ---------------------------------------------------------------------- main loop

   private static void tick(Minecraft client) {
      SectionUpdateRouter currentRouter = router;
      if (currentRouter == null) {
         return;
      }

      updatePlayerSnapshot(client);
      if (havePlayerPosition && protectionRescanNeeded()) {
         updateProtectionBand();
      }

      drainUrgentNeutral(currentRouter);

      long geometryKey = SeasonDirector.currentFrame().geometryKey();
      if (geometryKey != queuedGeometryKey) {
         // Snow targets changed: every watched section's geometry is stale by definition.
         beginPass(geometryKey);
      }

      int budget = SEASONAL_BUDGET_PER_TICK;
      while (budget-- > 0 && pendingIndex < pending.size()) {
         long position = pending.get(pendingIndex++);
         if (!isStructural(position) || !WATCHED.contains(position)) {
            continue;
         }
         if (isHandoffUnsafe(position)) {
            if (PROTECTED.add(position)) {
               enqueueUrgentNeutral(position);
            }
            continue;
         }
         if (isStale(position, geometryKey)) {
            currentRouter.triggerRemesh(position);
         }
      }
   }

   private static void drainUrgentNeutral(SectionUpdateRouter currentRouter) {
      int budget = NEUTRAL_BUDGET_PER_TICK;
      while (budget-- > 0) {
         Long position = URGENT_NEUTRAL.poll();
         if (position == null) {
            break;
         }
         URGENT_NEUTRAL_SET.remove(position);
         if (WATCHED.contains(position) && isHandoffUnsafe(position)) {
            currentRouter.triggerRemesh(position);
         }
      }
   }

   private static void updatePlayerSnapshot(Minecraft client) {
      if (client == null || client.player == null) {
         havePlayerPosition = false;
         return;
      }
      playerX = client.player.getX();
      playerZ = client.player.getZ();
      int vanillaChunks = Math.max(3, client.options.renderDistance().get());
      handoffRadiusBlocks = vanillaChunks * 16 + 64;
      havePlayerPosition = true;
   }

   private static boolean protectionRescanNeeded() {
      if (Double.isNaN(lastSortX) || Double.isNaN(lastSortZ) || lastProtectionRadius != handoffRadiusBlocks) {
         return true;
      }
      double dx = playerX - lastSortX;
      double dz = playerZ - lastSortZ;
      return dx * dx + dz * dz >= RESORT_DISTANCE_SQ;
   }

   private static void updateProtectionBand() {
      for (long position : WATCHED) {
         boolean nowProtected = isHandoffUnsafe(position);
         boolean wasProtected = PROTECTED.contains(position);
         if (nowProtected && !wasProtected) {
            PROTECTED.add(position);
            enqueueUrgentNeutral(position);
         } else if (!nowProtected && wasProtected) {
            PROTECTED.remove(position);
            // Leaving the near band means this section now needs seasonal geometry.
            PROJECTED_GEOMETRY.remove(position);
            invalidateQueue();
         }
      }
      lastProtectionRadius = handoffRadiusBlocks;
      // Player has moved far enough that the nearest-first ordering is stale too.
      invalidateQueue();
   }

   private static void enqueueUrgentNeutral(long position) {
      if (URGENT_NEUTRAL_SET.add(position)) {
         URGENT_NEUTRAL.add(position);
      }
   }

   /** Rebuilds the work queue, nearest section to the player first. */
   private static void beginPass(long geometryKey) {
      List<Long> ordered = new ArrayList<>(WATCHED);
      if (havePlayerPosition) {
         ordered.sort((a, b) -> Double.compare(distanceSq(a), distanceSq(b)));
      }
      pending = ordered;
      pendingIndex = 0;
      queuedGeometryKey = geometryKey;
      lastSortX = playerX;
      lastSortZ = playerZ;
   }

   /** Forces the next tick to rebuild the queue against the current geometry key. */
   private static void invalidateQueue() {
      queuedGeometryKey = Long.MIN_VALUE;
   }

   private static double distanceSq(long position) {
      int scale = 1 << Math.max(0, WorldEngine.getLevel(position));
      double cx = (((long) WorldEngine.getX(position) << 5) + 16.0) * scale;
      double cz = (((long) WorldEngine.getZ(position) << 5) + 16.0) * scale;
      double dx = cx - playerX;
      double dz = cz - playerZ;
      return dx * dx + dz * dz;
   }

   private static boolean isStructural(long position) {
      int lvl = WorldEngine.getLevel(position);
      return lvl >= 0 && lvl <= MAX_STRUCTURAL_LOD;
   }

   /** Clears all per-section state; used on disconnect so a new world starts clean. */
   public static void reset() {
      WATCHED.clear();
      PROTECTED.clear();
      URGENT_NEUTRAL.clear();
      URGENT_NEUTRAL_SET.clear();
      PROJECTED_GEOMETRY.clear();
      pending = List.of();
      pendingIndex = 0;
      invalidateQueue();
      router = null;
   }
}
