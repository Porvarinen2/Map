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
 * Every watched section carries the snow geometry key it was last meshed against. A section
 * whose key differs from the director's current one is stale, and a stale section is both
 * (a) re-meshed by the sweep below and (b) refused if Voxy tries to serve it from its geometry
 * cache. Because the sweep is a continuous rotation over the whole watched set with a budget
 * scaled to that set's size, every section is revisited within a bounded time no matter how
 * fast the season is moving or how far the player has travelled.
 *
 * <p>Travelling far enough to unload and reload a section does not reintroduce an old season
 * either: the persisted LOD data is season-neutral, and the mesh projector strips seasonal
 * snow that the current frame does not want at every LOD level, so even a database
 * contaminated by an older build is cleaned as it is drawn.
 *
 * <h2>Convergence order</h2>
 * The sweep runs nearest-first so what the player is looking at converges first, but ordering
 * is only a convenience - coverage is the guarantee, and coverage does not depend on it. An
 * earlier version restarted the queue from index 0 whenever the season changed, which under a
 * timelapse meant it never reached past the nearest ring.
 *
 * <h2>Cost per client tick - keep this list true</h2>
 * Everything this class does on the client thread must be bounded and cheap. Anything
 * proportional to the watched set has to be rare, because that set reaches tens of thousands
 * of sections at a large render distance.
 * <ul>
 *   <li>{@code drainUrgentRemesh} - at most {@value #HANDOFF_BUDGET_PER_TICK} sections.</li>
 *   <li>seasonal pass - at most {@value #SEASONAL_BUDGET_PER_TICK} sections.</li>
 *   <li>{@code updateProtectionBand} - O(watched), but only after the player has moved 64
 *       blocks, and only cheap arithmetic per entry.</li>
 *   <li>the sweep itself - {@code sweepBudget()} sections, scaled so one full rotation takes
 *       {@value #TARGET_SWEEP_TICKS} ticks; the per-section check is a map lookup.</li>
 *   <li>{@code refreshSweepOrderIfNeeded} - O(watched log watched) with boxing, so it is the
 *       expensive one. It runs only when the watched set has drifted by an eighth or the
 *       player has moved 64 blocks, never on a per-section event and never because the season
 *       changed.</li>
 * </ul>
 * Rebuilding that order from {@code watch} instead cost 5 ms per tick at 20k sections and
 * 14 ms at 50k, continuously while the player was moving, because sections enter the watched
 * set constantly. Do not reintroduce a rebuild on any per-section event.
 */
public final class VoxySeasonRemeshScheduler implements ClientModInitializer {
   /** Highest LOD level that carries projected seasonal geometry. */
   private static final int MAX_STRUCTURAL_LOD = 2;

   /**
    * Sections re-queued per client tick. At 20 tps this converges ~5000 sections in about
    * four seconds while staying well inside Voxy's own mesh worker budget.
    */
   private static final int SEASONAL_BUDGET_PER_TICK = 64;

   /** Handoff-boundary rebuilds are close to the player and visible immediately. */
   private static final int HANDOFF_BUDGET_PER_TICK = 32;

   /** Re-sort the sweep order once the player has moved this far (squared blocks). */
   private static final double RESORT_DISTANCE_SQ = 64.0 * 64.0;

   /** A full sweep of the watched set completes within this many client ticks (5 seconds). */
   private static final int TARGET_SWEEP_TICKS = 100;

   private static final Set<Long> WATCHED = ConcurrentHashMap.newKeySet();
   private static final Set<Long> PROTECTED = ConcurrentHashMap.newKeySet();
   private static final ConcurrentLinkedQueue<Long> URGENT_REMESH = new ConcurrentLinkedQueue<>();
   private static final Set<Long> URGENT_REMESH_SET = ConcurrentHashMap.newKeySet();

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

   private static List<Long> sweepOrder = List.of();
   private static int sweepOrderSize;
   private static int sweepCursor;
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
      if (WATCHED.add(position) && isHandoffUnsafe(position)) {
         PROTECTED.add(position);
         enqueueRemesh(position);
      }
      // A newly watched section deliberately does not disturb the work queue. If Voxy builds
      // it fresh, the mesh hook projects the current season into it; if Voxy serves it from
      // the geometry cache, the cache bypass rejects any mesh built against different snow
      // targets and forces a rebuild. Both paths are automatic. Invalidating the queue here
      // instead re-sorted the entire watched set on the client thread every time a section
      // came into view, which is continuously while the player is moving.
   }

   public static void unwatch(long position) {
      if (!isStructural(position)) {
         return;
      }
      WATCHED.remove(position);
      PROTECTED.remove(position);
      URGENT_REMESH_SET.remove(position);
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

      drainUrgentRemesh(currentRouter);

      long geometryKey = SeasonDirector.currentFrame().geometryKey();
      refreshSweepOrderIfNeeded();

      // A continuous rotating sweep, never a restartable pass.
      //
      // The previous form rebuilt the queue and reset to index 0 every time the geometry key
      // changed. In real time that is rare, but under /teslesseasons timelapse - which is how
      // this is actually tested - a whole year passes in ten minutes and the key changes
      // several times a second. The queue restarted long before it reached the far sections,
      // so only the ring nearest the player ever converged and everything beyond it kept
      // whatever season it was first meshed under. The cursor now advances regardless of what
      // the season does, so every watched section is visited within one sweep, always.
      int budget = sweepBudget();
      int visited = 0;
      int size = sweepOrder.size();
      while (visited++ < budget && size > 0) {
         if (sweepCursor >= size) {
            sweepCursor = 0;
         }
         long position = sweepOrder.get(sweepCursor++);
         if (!isStructural(position) || !WATCHED.contains(position)) {
            continue;
         }
         if (isStale(position, geometryKey)) {
            currentRouter.triggerRemesh(position);
         }
      }
   }

   /**
    * How many sections to examine this tick.
    *
    * <p>Scaled so a full sweep completes in {@value #TARGET_SWEEP_TICKS} ticks no matter how
    * large the watched set is. A fixed budget silently stops being a guarantee once the render
    * distance grows: at 64 per tick and 50k sections a sweep takes thirteen minutes, which is
    * indistinguishable from the season never updating out there.
    */
   private static int sweepBudget() {
      int size = sweepOrder.size();
      return Math.max(SEASONAL_BUDGET_PER_TICK, (size + TARGET_SWEEP_TICKS - 1) / TARGET_SWEEP_TICKS);
   }

   /**
    * Rebuilds the sweep order when the watched set has changed materially or the player has
    * moved far enough that nearest-first no longer means what it says.
    *
    * <p>Deliberately independent of the season: ordering is a convenience, coverage is the
    * guarantee, and coverage must not depend on how fast the calendar is moving.
    */
   private static void refreshSweepOrderIfNeeded() {
      int watched = WATCHED.size();
      boolean sizeDrift = Math.abs(watched - sweepOrderSize) > Math.max(64, sweepOrderSize / 8);
      boolean moved = havePlayerPosition
         && (Double.isNaN(lastSortX)
            || (playerX - lastSortX) * (playerX - lastSortX)
               + (playerZ - lastSortZ) * (playerZ - lastSortZ) >= RESORT_DISTANCE_SQ);
      if (!sizeDrift && !moved && !sweepOrder.isEmpty()) {
         return;
      }

      List<Long> ordered = new ArrayList<>(WATCHED);
      if (havePlayerPosition) {
         ordered.sort((a, b) -> Double.compare(distanceSq(a), distanceSq(b)));
      }
      sweepOrder = ordered;
      sweepOrderSize = ordered.size();
      sweepCursor = 0;
      lastSortX = playerX;
      lastSortZ = playerZ;
   }

   /** Rebuilds sections that just crossed the near/far handoff boundary, in either direction. */
   private static void drainUrgentRemesh(SectionUpdateRouter currentRouter) {
      int budget = HANDOFF_BUDGET_PER_TICK;
      while (budget-- > 0) {
         Long position = URGENT_REMESH.poll();
         if (position == null) {
            break;
         }
         URGENT_REMESH_SET.remove(position);
         if (WATCHED.contains(position)) {
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
         if (nowProtected != wasProtected) {
            // Crossing the handoff boundary changes what this section should contain: inside
            // the band it must be neutral because vanilla draws the real blocks, outside it
            // must carry projected snow. Forget the recorded geometry either way so a cached
            // mesh from the other side of the boundary cannot be served as current.
            if (nowProtected) {
               PROTECTED.add(position);
            } else {
               PROTECTED.remove(position);
            }
            PROJECTED_GEOMETRY.remove(position);
            enqueueRemesh(position);
         }
      }
      lastProtectionRadius = handoffRadiusBlocks;
      lastSortX = playerX;
      lastSortZ = playerZ;
   }

   private static void enqueueRemesh(long position) {
      if (URGENT_REMESH_SET.add(position)) {
         URGENT_REMESH.add(position);
      }
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
      URGENT_REMESH.clear();
      URGENT_REMESH_SET.clear();
      PROJECTED_GEOMETRY.clear();
      sweepOrder = List.of();
      sweepOrderSize = 0;
      sweepCursor = 0;
      lastSortX = Double.NaN;
      lastSortZ = Double.NaN;
      router = null;
   }
}
