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
 *   <li>{@code beginPass} - O(watched log watched) with boxing, so it is the expensive one.
 *       It runs <em>only</em> when the frame's geometry key changes: never in a snow-free
 *       season, and roughly once every forty minutes while snow is moving.</li>
 * </ul>
 * Calling {@code beginPass} from {@code watch} instead cost 5 ms per tick at 20k sections and
 * 14 ms at 50k, continuously while the player was moving, because sections enter the watched
 * set constantly. Do not reintroduce a queue rebuild on any per-section event.
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

   /** Re-sort the work queue once the player has moved this far (squared blocks). */
   private static final double RESORT_DISTANCE_SQ = 64.0 * 64.0;

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
               enqueueRemesh(position);
            }
            continue;
         }
         if (isStale(position, geometryKey)) {
            currentRouter.triggerRemesh(position);
         }
      }
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
      URGENT_REMESH.clear();
      URGENT_REMESH_SET.clear();
      PROJECTED_GEOMETRY.clear();
      pending = List.of();
      pendingIndex = 0;
      invalidateQueue();
      router = null;
   }
}
