package fi.tesles.seasons.world;

import fi.tesles.seasons.SeasonEngine;
import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.compat.SeasonNeutrality;
import fi.tesles.seasons.fix061.VoxyNeutralSnapshot;
import fi.tesles.seasons.compat.VoxyServerMutationGuard;
import fi.tesles.seasons.debug.SeasonDebugController;
import fi.tesles.seasons.sector.SeasonDirector;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.world.system.FloraSystem;
import fi.tesles.seasons.world.system.LeafSystem;
import fi.tesles.seasons.world.system.SeasonCoordinateField;
import fi.tesles.seasons.world.system.SnowSystem;
import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashSet;
import fi.tesles.seasons.world.effect.SeasonalEffectContext;
import fi.tesles.seasons.world.effect.SeasonalWorldEffect;
import fi.tesles.seasons.world.effect.SeasonalWorldEffects;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.Map.Entry;
import net.minecraft.core.BlockPos;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.level.Level;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.levelgen.Heightmap.Types;

public final class SeasonalWorldReconciler {
   private static final int UPDATE_FLAGS = 18;
   private static final Map<Long, SeasonalWorldReconciler.WorkState> LOADED = new HashMap<>();
   private static final ArrayDeque<Long> ROUND_ROBIN = new ArrayDeque<>();
   private static final ArrayDeque<Long> URGENT = new ArrayDeque<>();
   private static final Set<Long> URGENT_SET = new HashSet<>();
   /** Frame revision the loaded set was last brought up to date against. */
   private static long lastQueuedRevision = Long.MIN_VALUE;
   private static long ticks;
   private static long deadlineNanos;
   private static int writesRemaining;
   private static long surfaceColumnsProcessed;
   private static long leafColumnsProcessed;
   private static long snowPlaced;
   private static long snowRemoved;
   private static long snowLayerChanges;
   private static long leavesRemoved;
   private static long leavesRestored;
   private static long floraRemoved;
   private static long floraRestored;
   private static long preSendChunks;

   private SeasonalWorldReconciler() {
   }

   public static void onChunkLoad(ServerLevel level, LevelChunk chunk) {
      if (isOverworld(level)) {
         long key = key(chunk);
         SeasonalWorldReconciler.WorkState previous = LOADED.put(key, new SeasonalWorldReconciler.WorkState(level, chunk));
         if (previous != null) {
            previous.flush();
         }

         ROUND_ROBIN.remove(key);
         ROUND_ROBIN.addLast(key);
         enqueueUrgent(key);
      }
   }

   public static void onChunkUnload(ServerLevel level, LevelChunk chunk) {
      if (isOverworld(level)) {
         long key = key(chunk);
         SeasonalWorldReconciler.WorkState state = LOADED.remove(key);
         if (state != null) {
            state.flush();
         }

         ROUND_ROBIN.remove(key);
         URGENT.remove(key);
         URGENT_SET.remove(key);
      }
   }

   public static void clear() {
      for (SeasonalWorldReconciler.WorkState state : LOADED.values()) {
         state.flush();
      }

      LOADED.clear();
      ROUND_ROBIN.clear();
      URGENT.clear();
      URGENT_SET.clear();
      ticks = 0L;
   }

   public static void queuePlayerVicinityUrgent(MinecraftServer server) {
      for (ServerLevel level : server.getAllLevels()) {
         if (isOverworld(level)) {
            for (ServerPlayer player : level.players()) {
               int cx = player.chunkPosition().x();
               int cz = player.chunkPosition().z();
               int r = Math.max(2, Math.min(8, TeslesSeasons.CONFIG.playerPriorityRadiusChunks));

               for (int dx = -r; dx <= r; dx++) {
                  for (int dz = -r; dz <= r; dz++) {
                     long k = key(cx + dx, cz + dz);
                     if (LOADED.containsKey(k)) {
                        enqueueUrgent(k);
                     }
                  }
               }
            }
         }
      }
   }

   public static void queueAllLoadedUrgent() {
      for (Long key : LOADED.keySet()) {
         enqueueUrgent(key);
      }
   }

   private static void canonicalizePlayerHotset(MinecraftServer server, SeasonFrame frame, boolean debug) {
      int fullPerPlayer = debug ? 5 : 2;
      int surfacePerPlayer = debug ? 24 : 6;

      for (ServerLevel level : server.getAllLevels()) {
         if (isOverworld(level)) {
            for (ServerPlayer player : level.players()) {
               int cx = player.chunkPosition().x();
               int cz = player.chunkPosition().z();
               int radius = Math.max(2, Math.min(8, TeslesSeasons.CONFIG.playerPriorityRadiusChunks));
               int side = radius * 2 + 1;
               int total = side * side;
               SeasonalWorldReconciler.WorkState center = LOADED.get(key(cx, cz));
               if (center != null) {
                  center.canonicalizeVisibleBeforeSend(frame);
               }

               int fullDone = 1;
               int surfaceDone = 1;
               int start = (int)((ticks * 37L + player.getId() * 17L) % total);

               for (int step = 0; step < total && surfaceDone < surfacePerPlayer; step++) {
                  int idx = Math.floorMod(start + step * 73, total);
                  int dx = idx % side - radius;
                  int dz = idx / side - radius;
                  if (dx != 0 || dz != 0) {
                     SeasonalWorldReconciler.WorkState state = LOADED.get(key(cx + dx, cz + dz));
                     if (state != null) {
                        if (fullDone < fullPerPlayer) {
                           state.canonicalizeVisibleBeforeSend(frame);
                           fullDone++;
                        } else {
                           state.canonicalizeSurfaceOnly(frame);
                        }

                        surfaceDone++;
                     }
                  }
               }
            }
         }
      }
   }

   public static void tick(MinecraftServer server, SeasonSnapshot snapshot) {
      ticks++;
      if (snapshot != null && !LOADED.isEmpty()) {
         SeasonFrame frame = SeasonDirector.currentFrame();
         boolean debug = SeasonDebugController.isActive();

         // Revision coalescing. The director mints a revision only when the frame's targets
         // actually change, so this fires once per real change rather than once per percent,
         // and a burst of 53% -> 54% -> 55% collapses into a single pass straight to 55%.
         if (frame.revision() != lastQueuedRevision) {
            lastQueuedRevision = frame.revision();
            queueAllLoadedUrgent();
         }

         canonicalizePlayerHotset(server, frame, debug);
         if ((ticks & 7L) == 0L) {
            queuePlayerVicinityUrgent(server);
         }

         int surfaceBudget = debug
            ? Math.max(64, Math.min(384, TeslesSeasons.CONFIG.surfaceColumnsPerTick * 4))
            : Math.max(8, Math.min(96, TeslesSeasons.CONFIG.surfaceColumnsPerTick));
         int leafBudget = debug
            ? Math.max(96, Math.min(1024, TeslesSeasons.CONFIG.debugLeafColumnsPerTick))
            : Math.max(8, Math.min(128, TeslesSeasons.CONFIG.leafColumnsPerTick));
         int snowWrites = Math.max(8, Math.min(256, TeslesSeasons.CONFIG.maxVisibleSnowWritesPerTick));
         int leafWrites = debug
            ? Math.max(16, Math.min(384, TeslesSeasons.CONFIG.debugMaxVisibleLeafWritesPerTick))
            : Math.max(8, Math.min(192, TeslesSeasons.CONFIG.maxVisibleLeafWritesPerTick));
         writesRemaining = snowWrites + leafWrites;
         long micros = debug
            ? Math.min(6500L, Math.max(1200L, TeslesSeasons.CONFIG.debugReconcileBudgetMicros))
            : Math.min(2500L, Math.max(500L, TeslesSeasons.CONFIG.worldReconcileBudgetMicros));
         deadlineNanos = System.nanoTime() + micros * 1000L;
         int surfaceDone = 0;
         int leafDone = 0;
         int visitsLeft = Math.max(1, Math.min(512, LOADED.size() * 2 + URGENT.size()));

         while (visitsLeft-- > 0 && canWork() && (surfaceDone < surfaceBudget || leafDone < leafBudget)) {
            SeasonalWorldReconciler.WorkState state = nextState();
            if (state == null) {
               break;
            }

            if (surfaceDone < surfaceBudget) {
               surfaceDone += state.processSurface(frame, Math.min(16, surfaceBudget - surfaceDone));
            }

            if (leafDone < leafBudget && canWork()) {
               leafDone += state.processLeaves(frame, Math.min(8, leafBudget - leafDone));
            }

            state.flushIfDirty();
         }
      }
   }

   public static void reconcileBeforeSend(ServerLevel level, LevelChunk chunk) {
      if (TeslesSeasons.CONFIG.preSendSeasonProjection && isOverworld(level)) {
         long k = key(chunk);
         SeasonalWorldReconciler.WorkState state = LOADED.get(k);
         if (state == null) {
            state = new SeasonalWorldReconciler.WorkState(level, chunk);
            LOADED.put(k, state);
            ROUND_ROBIN.remove(k);
            ROUND_ROBIN.addLast(k);
         }

         // Canonicalise against the authoritative frame, not a re-derivation, so a chunk can
         // never become visible carrying a season the director has already moved past.
         state.canonicalizeVisibleBeforeSend(SeasonDirector.currentFrame());

         enqueueUrgent(k);
         preSendChunks++;
      }
   }

   /**
    * The numbers a diagnostic capture needs, without parsing the status string.
    *
    * <p>{@link #status()} exists for a human reading a HUD; this exists for a machine writing a time
    * series. Neither should be built by taking the other apart.
    */
   public record Counters(int loaded, int urgent, int ledgerLeaves, int ledgerFlora,
                          long snowPlaced, long leavesRemoved, long leavesRestored) {
   }

   public static Counters counters() {
      return new Counters(LOADED.size(), URGENT.size(), pendingLedger(true), pendingLedger(false),
         snowPlaced, leavesRemoved, leavesRestored);
   }

   public static String status() {
      return "0.7.0 sectorized loaded="
         + LOADED.size()
         + " rr="
         + ROUND_ROBIN.size()
         + " urgent="
         + URGENT.size()
         + " surfaceCols="
         + surfaceColumnsProcessed
         + " leafCols="
         + leafColumnsProcessed
         + " snow+="
         + snowPlaced
         + " snow-="
         + snowRemoved
         + " layers="
         + snowLayerChanges
         + " leaves-="
         + leavesRemoved
         + " leaves+="
         + leavesRestored
         + " flora-="
         + floraRemoved
         + " flora+="
         + floraRestored
         + " preSendQueued="
         + preSendChunks
         + " ledger[leaves="
         + pendingLedger(true)
         + ",flora="
         + pendingLedger(false)
         + "] "
         + VoxyNeutralSnapshot.summary();
   }

   /**
    * Entries still owed back across loaded chunks.
    *
    * <p>The leaf ledger is what lets a winter chunk be handed to Voxy as a summer one, and it is
    * the only record of which leaf stood where. If it is empty while the world is bare, nothing
    * can restore the canopy - not the world in spring and not the LOD at any point - so its size
    * is the first thing worth knowing when distant trees will not come back.
    */
   private static int pendingLedger(boolean leaves) {
      int total = 0;
      for (SeasonalWorldReconciler.WorkState state : LOADED.values()) {
         total += leaves ? state.removedLeaves.size() : state.removedFlora.size();
      }
      return total;
   }

   public static float positionNoise(BlockPos pos, long seed) {
      return SeasonCoordinateField.leaf01(pos, seed);
   }

   /**
    * The column a chunk's sweep visits at {@code index}.
    *
    * <p>{@code start + index * step (mod 256)} with an odd step is a full-cycle permutation of
    * 0..255, so one sweep touches every column exactly once and no column can starve. The step is
    * forced odd by the {@code | 1}; an even step would revisit a fraction of the columns and never
    * reach the rest.
    */
   /**
    * Whether the frame asks for nothing to be taken out of the world.
    *
    * <p>For most of the year every retention is full and there is no snow, and in that state a
    * column sweep can only ever confirm that everything is already where it should be. Confirming
    * it is not free: each column costs a heightmap lookup, a surface-flora search and a short
    * vertical scan of block states, and the pre-send pass runs all 256 columns of a chunk with no
    * budget at all. Checking the frame once and skipping the column outright is what keeps a
    * summer afternoon from costing the same as a thaw.
    */
   private static boolean frameRemovesNothing(SeasonFrame f) {
      return f.snowCoverage() <= 0.0F
         && f.plantRetention() >= 0.9999F
         && f.flowerRetention() >= 0.9999F
         && f.mushroomRetention() >= 0.9999F
         && f.berryRetention() >= 0.9999F;
   }

   private static boolean frameDropsNoLeaves(SeasonFrame f) {
      return f.leafRetention() >= 0.9999F && f.mushroomRetention() >= 0.9999F;
   }

   public static int columnOrder(int chunkX, int chunkZ, int index, int sweep) {
      int seed = chunkX * 73428767 ^ chunkZ * 912931 ^ sweep;
      int start = seed & 0xFF;
      int step = (seed >>> 8 | 1) & 0xFF;
      return start + index * step & 0xFF;
   }

   private static final Set<String> REPORTED_EFFECT_FAILURES = ConcurrentHashMap.newKeySet();

   /** Logs an effect's first failure and then stays quiet about it. */
   private static void reportEffectFailure(String effectId, Throwable failure) {
      if (REPORTED_EFFECT_FAILURES.add(effectId)) {
         TeslesSeasons.LOGGER.error("Seasonal world effect '{}' failed and was skipped for this column.", effectId, failure);
      }
   }

   private static boolean canWork() {
      return writesRemaining > 0 && System.nanoTime() < deadlineNanos;
   }

   private static SeasonalWorldReconciler.WorkState nextState() {
      Long k = URGENT.pollFirst();
      if (k != null) {
         URGENT_SET.remove(k);
      }

      if (k == null) {
         k = ROUND_ROBIN.pollFirst();
         if (k != null) {
            ROUND_ROBIN.addLast(k);
         }
      }

      return k == null ? null : LOADED.get(k);
   }

   private static void enqueueUrgent(long k) {
      if (URGENT_SET.add(k)) {
         URGENT.addLast(k);
      }
   }

   private static long key(LevelChunk chunk) {
      return key(chunk.getPos().x(), chunk.getPos().z());
   }

   private static long key(int x, int z) {
      return (long)x << 32 ^ z & 4294967295L;
   }

   private static boolean isOverworld(ServerLevel level) {
      return Level.OVERWORLD.equals(level.dimension());
   }

   private static int surfaceRevision(SeasonFrame f) {
      int h = f.season().ordinal() * 10000000
         + f.phase().ordinal() * 1000000
         + Math.round(f.snowCoverage() * 100.0F) * 10000
         + Math.round(f.snowDepth() * 100.0F) * 100
         + Math.round(f.flowerRetention() * 100.0F);
      h = h * 101 + Math.round(f.plantRetention() * 100.0F);
      return h * 101 + Math.round(f.mushroomRetention() * 100.0F);
   }

   private static int leafRevision(SeasonFrame f) {
      int h = f.season().ordinal() * 100000 + f.phase().ordinal() * 10000 + Math.round(f.leafRetention() * 100.0F);
      return h * 101 + Math.round(f.mushroomRetention() * 100.0F);
   }

   private static final class WorkState {
      final ServerLevel level;
      final LevelChunk chunk;
      /** Per-effect ownership, mirroring the chunk's EFFECT_OWNED attachment. */
      final Map<String, LinkedHashSet<Long>> effectOwned = new LinkedHashMap<>();
      final Set<Long> ownedSnow = new HashSet<>();
      final Map<Integer, LinkedHashSet<Long>> ownedSnowByColumn = new HashMap<>();
      final Map<Long, String> removedLeaves = new HashMap<>();
      final Map<Long, String> removedFlora = new HashMap<>();
      final Map<Integer, LinkedHashSet<Long>> removedLeavesByColumn = new HashMap<>();
      final Map<Integer, LinkedHashSet<Long>> removedFloraByColumn = new HashMap<>();
      int surfaceCursor;
      int leafCursor;
      /** Sweep number, incremented each time a cursor wraps. Chooses the column order. */
      int surfaceSweep;
      int leafSweep;
      /**
       * Columns visited since the current revision was adopted, capped at 256.
       *
       * <p>This, not the cursor, is what says whether a chunk is current: once 256 columns have
       * been visited the sweep has necessarily covered every column at least once under this
       * revision or a newer one.
       */
      int surfaceColumnsSinceRevision;
      int leafColumnsSinceRevision;
      int surfaceRevision = Integer.MIN_VALUE;
      int leafRevision = Integer.MIN_VALUE;
      boolean dirty;
      int writeCounter;
      int writesSinceFlush;

      WorkState(ServerLevel level, LevelChunk chunk) {
         this.level = level;
         this.chunk = chunk;

         for (long packed : SeasonalWorldData.readOwnedSnow(chunk)) {
            this.ownedSnow.add(packed);
            index(this.ownedSnowByColumn, packed);
         }

         for (Map.Entry<String, List<Long>> entry : SeasonalWorldData.readEffectOwned(chunk).entrySet()) {
            this.effectOwned.put(entry.getKey(), new LinkedHashSet<>(entry.getValue()));
         }

         for (String e : SeasonalWorldData.readRemovedLeaves(chunk)) {
            long packed = SeasonalWorldData.encodedPackedPos(e);
            this.removedLeaves.put(packed, e);
            index(this.removedLeavesByColumn, packed);
         }

         for (String e : SeasonalWorldData.readRemovedFlora(chunk)) {
            long packed = SeasonalWorldData.encodedFloraPackedPos(e);
            this.removedFlora.put(packed, e);
            index(this.removedFloraByColumn, packed);
         }
      }

      void canonicalizeSurfaceOnly(SeasonFrame frame) {
         int targetSurfaceRevision = SeasonalWorldReconciler.surfaceRevision(frame);
         if (this.surfaceRevision != targetSurfaceRevision || this.surfaceColumnsSinceRevision < 256) {
            long oldDeadline = SeasonalWorldReconciler.deadlineNanos;
            int oldWrites = SeasonalWorldReconciler.writesRemaining;
            SeasonalWorldReconciler.deadlineNanos = Long.MAX_VALUE;
            SeasonalWorldReconciler.writesRemaining = 536870911;

            try {
               for (int column = 0; column < 256; column++) {
                  this.processSurfaceColumn(column, frame);
               }

               this.surfaceRevision = targetSurfaceRevision;
               this.surfaceColumnsSinceRevision = 256;
               this.flush();
            } finally {
               SeasonalWorldReconciler.deadlineNanos = oldDeadline;
               SeasonalWorldReconciler.writesRemaining = oldWrites;
            }
         }
      }

      void canonicalizeVisibleBeforeSend(SeasonFrame frame) {
         // Every chunk sent to a player runs a full, unbudgeted 256-column surface pass and a
         // 256-column canopy pass, so that a chunk can never become visible carrying a season the
         // director has already moved past. When the frame takes nothing out of the world and this
         // chunk owes nothing back, that guarantee holds trivially and the passes would only
         // rediscover it - at the cost of a heightmap lookup and a vertical block scan per column,
         // on the server thread, for every chunk a moving player pulls in.
         if (frameRemovesNothing(frame)
            && frameDropsNoLeaves(frame)
            && this.ownedSnow.isEmpty()
            && this.removedLeaves.isEmpty()
            && this.removedFlora.isEmpty()) {
            this.surfaceRevision = SeasonalWorldReconciler.surfaceRevision(frame);
            this.leafRevision = SeasonalWorldReconciler.leafRevision(frame);
            this.surfaceColumnsSinceRevision = 256;
            this.leafColumnsSinceRevision = 256;
            return;
         }

         long oldDeadline = SeasonalWorldReconciler.deadlineNanos;
         int oldWrites = SeasonalWorldReconciler.writesRemaining;
         SeasonalWorldReconciler.deadlineNanos = Long.MAX_VALUE;
         SeasonalWorldReconciler.writesRemaining = 536870911;

         try {
            int targetSurfaceRevision = SeasonalWorldReconciler.surfaceRevision(frame);
            if (this.surfaceRevision != targetSurfaceRevision || this.surfaceColumnsSinceRevision < 256) {
               for (int column = 0; column < 256; column++) {
                  this.processSurfaceColumn(column, frame);
               }

               this.surfaceRevision = targetSurfaceRevision;
               this.surfaceColumnsSinceRevision = 256;
            }

            this.restoreEligibleLeavesFromMetadata(frame);
            int targetLeafRevision = SeasonalWorldReconciler.leafRevision(frame);
            if (this.leafRevision != targetLeafRevision || this.leafColumnsSinceRevision < 256) {
               for (int column = 0; column < 256; column++) {
                  this.processLeafColumn(column, frame);
               }

               this.leafRevision = targetLeafRevision;
               this.leafColumnsSinceRevision = 256;
            }

            this.flush();
         } finally {
            SeasonalWorldReconciler.deadlineNanos = oldDeadline;
            SeasonalWorldReconciler.writesRemaining = oldWrites;
         }
      }

      private void restoreEligibleLeavesFromMetadata(SeasonFrame frame) {
         if (!this.removedLeaves.isEmpty() && !(frame.leafRetention() <= 1.0E-4F)) {
            long seed = SeasonEngine.current().visualSeed();
            Iterator<Entry<Long, String>> it = this.removedLeaves.entrySet().iterator();
            boolean changed = false;

            while (it.hasNext()) {
               Entry<Long, String> entry = it.next();
               SeasonalWorldData.DecodedState decoded = SeasonalWorldData.decodeState(this.chunk, entry.getValue());
               if (decoded == null) {
                  it.remove();
                  changed = true;
               } else if (LeafSystem.shouldExist(decoded.pos(), frame, seed)) {
                  if (!this.level.getBlockState(decoded.pos()).isAir()) {
                     it.remove();
                     changed = true;
                  } else if (this.trySetLeaf(decoded.pos(), decoded.state())) {
                     SeasonalWorldReconciler.leavesRestored++;
                     it.remove();
                     changed = true;
                  }
               }
            }

            if (changed) {
               this.removedLeavesByColumn.clear();

               for (long packed : this.removedLeaves.keySet()) {
                  index(this.removedLeavesByColumn, packed);
               }

               this.dirty = true;
            }
         }
      }

      /**
       * Advances this chunk's surface sweep by up to {@code count} columns.
       *
       * <p>The cursor is deliberately <em>not</em> reset when the revision changes. It used to be,
       * and that quietly starved everything outside the player's vicinity: a surface revision is
       * quantised at 1/100 per channel, so during a fast timelapse it changed roughly every half
       * second while any individual chunk came up for its turn only every couple of seconds. The
       * cursor was therefore back at zero on nearly every visit, the same handful of columns were
       * redone forever, and the rest of the chunk was never reached at all. Near chunks looked
       * right only because the player hotset canonicalises them in full by a separate path.
       *
       * <p>Sweeping continuously fixes that: each column is evaluated against whatever frame is
       * current when its turn comes, and no column can be skipped more than one wrap in a row.
       */
      int processSurface(SeasonFrame frame, int count) {
         int rev = SeasonalWorldReconciler.surfaceRevision(frame);
         if (this.surfaceRevision != rev) {
            this.surfaceRevision = rev;
            this.surfaceColumnsSinceRevision = 0;
         }

         int done;
         for (done = 0; done < count && SeasonalWorldReconciler.canWork(); done++) {
            if (this.surfaceCursor >= 256) {
               this.surfaceCursor = 0;
               this.surfaceSweep++;
            }

            if (!this.processSurfaceColumn(this.permuted(this.surfaceCursor, this.surfaceSweep), frame)) {
               break;
            }

            this.surfaceCursor++;
            if (this.surfaceColumnsSinceRevision < 256) {
               this.surfaceColumnsSinceRevision++;
            }
         }

         SeasonalWorldReconciler.surfaceColumnsProcessed += done;
         return done;
      }

      /** Leaf sweep. Continuous for the same reason {@link #processSurface} is. */
      int processLeaves(SeasonFrame frame, int count) {
         int rev = SeasonalWorldReconciler.leafRevision(frame);
         if (this.leafRevision != rev) {
            this.leafRevision = rev;
            this.leafColumnsSinceRevision = 0;
         }

         int done;
         for (done = 0; done < count && SeasonalWorldReconciler.canWork(); done++) {
            if (this.leafCursor >= 256) {
               this.leafCursor = 0;
               this.leafSweep++;
            }

            if (!this.processLeafColumn(this.permuted(this.leafCursor, this.leafSweep), frame)) {
               break;
            }

            this.leafCursor++;
            if (this.leafColumnsSinceRevision < 256) {
               this.leafColumnsSinceRevision++;
            }
         }

         SeasonalWorldReconciler.leafColumnsProcessed += done;
         return done;
      }

      private boolean processSurfaceColumn(int column, SeasonFrame frame) {
         int lx = column & 15;
         int lz = column >>> 4 & 15;
         int columnKey = lz << 4 | lx;

         // Nothing to place, nothing owed back, nothing the frame wants removed: the column is
         // already correct and touching the world at all would only cost lookups.
         if (frameRemovesNothing(frame)
            && !this.ownedSnowByColumn.containsKey(columnKey)
            && !this.removedFloraByColumn.containsKey(columnKey)) {
            return true;
         }

         int wx = (this.chunk.getPos().x() << 4) + lx;
         int wz = (this.chunk.getPos().z() << 4) + lz;
         int top = this.level.getHeight(Types.MOTION_BLOCKING_NO_LEAVES, wx, wz) - 1;
         if (top < this.level.getMinY()) {
            return true;
         } else {
            BlockPos ground = new BlockPos(wx, top, wz);

            while (SnowSystem.isSnowLayer(this.level.getBlockState(ground)) && ground.getY() > this.level.getMinY()) {
               ground = ground.below();
            }

            BlockPos snowPos = ground.above();
            int target = SnowSystem.targetLayers(frame, wx, wz, SeasonEngine.current().visualSeed());
            BlockState currentAtSnow = this.level.getBlockState(snowPos);
            if (target > 0) {
               BlockPos floraPos = FloraSystem.findSurfaceFlora(this.level, ground);
               if (floraPos != null) {
                  BlockPos baseFloraPos = this.lowerPlantBase(floraPos);
                  BlockState desiredAtFlora = SnowSystem.snowStateFor(this.level, baseFloraPos, target);
                  if (desiredAtFlora.canSurvive(this.level, baseFloraPos)) {
                     if (!this.removeSeasonalFloraPlant(baseFloraPos)) {
                        return false;
                     }

                     snowPos = baseFloraPos;
                     currentAtSnow = this.level.getBlockState(baseFloraPos);
                  }
               }

               // Ownership gate: grow depth only on snow we placed. Pre-existing snow that
               // happens to sit where the season also wants snow stays the player's, and is
               // therefore never overwritten here nor deleted in the melt branch below.
               long ownedPacked = SeasonalWorldData.packLocal(snowPos);
               boolean seasonOwned = this.ownedSnow.contains(ownedPacked);
               if (currentAtSnow.isAir() || (seasonOwned && SnowSystem.isSnowLayer(currentAtSnow))) {
                  int oldLayers = SnowSystem.layers(currentAtSnow);
                  BlockState desired = SnowSystem.snowStateFor(this.level, snowPos, target);
                  if (desired.canSurvive(this.level, snowPos)) {
                     if (!currentAtSnow.equals(desired)) {
                        if (!this.trySetSurface(snowPos, desired)) {
                           return false;
                        }

                        if (oldLayers == 0) {
                           SeasonalWorldReconciler.snowPlaced++;
                        } else {
                           SeasonalWorldReconciler.snowLayerChanges++;
                        }
                     }

                     if (this.ownedSnow.add(ownedPacked)) {
                        index(this.ownedSnowByColumn, ownedPacked);
                     }

                     this.dirty = true;
                  }
               }
            } else {
               if (SnowSystem.isSnowLayer(currentAtSnow)
                     && this.ownedSnow.contains(SeasonalWorldData.packLocal(snowPos))) {
                  if (!this.trySetFlora(snowPos, this.springGroundCoverState(snowPos))) {
                     return false;
                  }

                  SeasonalWorldReconciler.snowRemoved++;
               }

               if (!this.removeOwnedSnowInColumn(lx, lz)) {
                  return false;
               }

               if (!this.restoreFloraInColumn(lx, lz, frame)) {
                  return false;
               }
            }

            if (!this.reconcileSeasonFloraInColumn(lx, lz, frame)) {
               return false;
            }

            return this.applyWorldEffects(wx, wz, frame);
         }
      }

      /**
       * Runs the installed {@link SeasonalWorldEffect}s over one column.
       *
       * <p>They run after the built-in snow, leaf and flora work, so an effect sees the column as
       * the season has already left it - ice forms on water the snow pass has decided not to cover,
       * not on water it is about to. Nothing happens at all when no effect asks for this frame,
       * which for most of the year is every one of them.
       */
      private boolean applyWorldEffects(int wx, int wz, SeasonFrame frame) {
         List<SeasonalWorldEffect> effects = SeasonalWorldEffects.active(frame);
         if (effects.isEmpty()) {
            return true;
         }

         for (SeasonalWorldEffect effect : effects) {
            if (!SeasonalWorldReconciler.canWork()) {
               return false;
            }

            SeasonalWorldReconciler.WorkState.EffectColumn column =
               new SeasonalWorldReconciler.WorkState.EffectColumn(effect.id(), wx, wz, frame);
            try {
               if (!effect.applyToColumn(column)) {
                  return false;
               }
            } catch (Throwable failure) {
               // One misbehaving effect must not take the season system down with it.
               SeasonalWorldReconciler.reportEffectFailure(effect.id(), failure);
            }
         }

         return true;
      }

      /** {@link SeasonalEffectContext} bound to one column of this chunk. */
      private final class EffectColumn implements SeasonalEffectContext {
         private final String effectId;
         private final int wx;
         private final int wz;
         private final SeasonFrame frame;
         private BlockPos surface;

         private EffectColumn(String effectId, int wx, int wz, SeasonFrame frame) {
            this.effectId = effectId;
            this.wx = wx;
            this.wz = wz;
            this.frame = frame;
         }

         @Override
         public ServerLevel level() {
            return WorkState.this.level;
         }

         @Override
         public SeasonFrame frame() {
            return this.frame;
         }

         @Override
         public long seed() {
            return SeasonEngine.current().visualSeed();
         }

         @Override
         public int x() {
            return this.wx;
         }

         @Override
         public int z() {
            return this.wz;
         }

         @Override
         public BlockPos surface() {
            if (this.surface == null) {
               int top = WorkState.this.level.getHeight(Types.MOTION_BLOCKING_NO_LEAVES, this.wx, this.wz) - 1;
               this.surface = new BlockPos(this.wx, Math.max(WorkState.this.level.getMinY(), top), this.wz);
            }
            return this.surface;
         }

         @Override
         public BlockState stateAt(BlockPos pos) {
            return WorkState.this.level.getBlockState(pos);
         }

         @Override
         public boolean place(BlockPos pos, BlockState state) {
            // An effect placing a block is the season diverging from the neutral world by
            // definition, so it is held out of Voxy's LOD store without the effect having to know
            // that store exists. Every future effect gets this for free, and correctly.
            if (!VoxyServerMutationGuard.runSuppressingLodDivergence(() -> WorkState.this.trySet(pos, state))) {
               return false;
            }
            this.markOwned(pos);
            return true;
         }

         @Override
         public boolean restore(BlockPos pos, BlockState state) {
            if (!this.owns(pos)) {
               return true;
            }
            // Undoing an effect brings the world back toward neutral, so it is allowed through to
            // the LOD - that is what lets a distant lake stop being frozen.
            if (!WorkState.this.trySet(pos, state)) {
               return false;
            }

            LinkedHashSet<Long> owned = WorkState.this.effectOwned.get(this.effectId);
            if (owned != null && owned.remove(SeasonalWorldData.packLocal(pos)) && owned.isEmpty()) {
               WorkState.this.effectOwned.remove(this.effectId);
            }
            WorkState.this.dirty = true;
            return true;
         }

         @Override
         public boolean owns(BlockPos pos) {
            LinkedHashSet<Long> owned = WorkState.this.effectOwned.get(this.effectId);
            return owned != null && owned.contains(SeasonalWorldData.packLocal(pos));
         }

         @Override
         public void markOwned(BlockPos pos) {
            if (WorkState.this.effectOwned
               .computeIfAbsent(this.effectId, ignored -> new LinkedHashSet<>())
               .add(SeasonalWorldData.packLocal(pos))) {
               WorkState.this.dirty = true;
            }
         }

         @Override
         public Iterable<BlockPos> ownedInColumn() {
            LinkedHashSet<Long> owned = WorkState.this.effectOwned.get(this.effectId);
            if (owned == null || owned.isEmpty()) {
               return List.of();
            }

            int columnKey = (this.wz & 15) << 4 | this.wx & 15;
            List<BlockPos> here = new ArrayList<>();
            for (long packed : owned) {
               if (SeasonalWorldData.localColumnKey(packed) == columnKey) {
                  here.add(SeasonalWorldData.unpackLocal(WorkState.this.chunk, packed));
               }
            }
            return here;
         }

         @Override
         public boolean canWork() {
            return SeasonalWorldReconciler.canWork();
         }
      }

      private boolean processLeafColumn(int column, SeasonFrame frame) {
         int lx = column & 15;
         int lz = column >>> 4 & 15;

         // The canopy scan reads up to ninety-six block states per column. With a full canopy and
         // nothing recorded as removed here there is provably nothing for it to find, and this is
         // the single most expensive thing the reconciler does.
         if (frameDropsNoLeaves(frame) && !this.removedLeavesByColumn.containsKey(lz << 4 | lx)) {
            return true;
         }

         int wx = (this.chunk.getPos().x() << 4) + lx;
         int wz = (this.chunk.getPos().z() << 4) + lz;
         int top = this.level.getHeight(Types.MOTION_BLOCKING, wx, wz);
         int min = Math.max(this.level.getMinY(), top - Math.max(24, Math.min(96, TeslesSeasons.CONFIG.canopyScanDepth)));
         long seed = SeasonEngine.current().visualSeed();

         for (int y = top; y >= min; y--) {
            if (!SeasonalWorldReconciler.canWork()) {
               return false;
            }

            BlockPos pos = new BlockPos(wx, y, wz);
            BlockState state = this.level.getBlockState(pos);
            if (LeafSystem.isDeciduous(state) && !LeafSystem.shouldExist(pos, frame, seed)) {
               if (!this.trySetLeaf(pos, Blocks.AIR.defaultBlockState())) {
                  return false;
               }

               long packed = SeasonalWorldData.packLocal(pos);
               if (this.removedLeaves.putIfAbsent(packed, SeasonalWorldData.encodeState(pos, state)) == null) {
                  index(this.removedLeavesByColumn, packed);
               }

               SeasonalWorldReconciler.leavesRemoved++;
               this.dirty = true;
            } else {
               SeasonalFloraKind canopyFlora = FloraSystem.kind(state);
               if (canopyFlora == SeasonalFloraKind.MUSHROOM
                  && !FloraSystem.shouldExist(canopyFlora, pos, this.level.getBlockState(pos), frame, seed)
                  && !this.removeSeasonalFloraPlant(pos)) {
                  return false;
               }
            }
         }

         int columnKey = lz << 4 | lx;
         LinkedHashSet<Long> columnLeaves = this.removedLeavesByColumn.get(columnKey);
         if (columnLeaves != null) {
            Iterator<Long> it = columnLeaves.iterator();

            while (it.hasNext()) {
               if (!SeasonalWorldReconciler.canWork()) {
                  return false;
               }

               long packed = it.next();
               String encoded = this.removedLeaves.get(packed);
               if (encoded == null) {
                  it.remove();
               } else {
                  SeasonalWorldData.DecodedState decoded = SeasonalWorldData.decodeState(this.chunk, encoded);
                  if (decoded == null) {
                     this.removedLeaves.remove(packed);
                     it.remove();
                     this.dirty = true;
                  } else if (LeafSystem.shouldExist(decoded.pos(), frame, seed) && this.level.getBlockState(decoded.pos()).isAir()) {
                     if (!this.trySetLeaf(decoded.pos(), decoded.state())) {
                        return false;
                     }

                     SeasonalWorldReconciler.leavesRestored++;
                     this.removedLeaves.remove(packed);
                     it.remove();
                     this.dirty = true;
                  }
               }
            }

            if (columnLeaves.isEmpty()) {
               this.removedLeavesByColumn.remove(columnKey);
            }
         }

         return true;
      }

      private boolean removeOwnedSnowInColumn(int lx, int lz) {
         int columnKey = lz << 4 | lx;
         LinkedHashSet<Long> columnSnow = this.ownedSnowByColumn.get(columnKey);
         if (columnSnow == null) {
            return true;
         } else {
            for (Iterator<Long> it = columnSnow.iterator(); it.hasNext(); this.dirty = true) {
               if (!SeasonalWorldReconciler.canWork()) {
                  return false;
               }

               long packed = it.next();
               BlockPos pos = SeasonalWorldData.unpackLocal(this.chunk, packed);
               BlockState state = this.level.getBlockState(pos);
               if (SnowSystem.isSnowLayer(state)) {
                  BlockState replacement = this.springGroundCoverState(pos);
                  if (!this.trySetFlora(pos, replacement)) {
                     return false;
                  }

                  SeasonalWorldReconciler.snowRemoved++;
               }

               this.ownedSnow.remove(packed);
               it.remove();
            }

            if (columnSnow.isEmpty()) {
               this.ownedSnowByColumn.remove(columnKey);
            }

            return true;
         }
      }

      private boolean restoreFloraInColumn(int lx, int lz, SeasonFrame frame) {
         long seed = SeasonEngine.current().visualSeed();
         int columnKey = lz << 4 | lx;
         LinkedHashSet<Long> columnFlora = this.removedFloraByColumn.get(columnKey);
         if (columnFlora == null) {
            return true;
         } else {
            Iterator<Long> it = columnFlora.iterator();

            while (it.hasNext()) {
               if (!SeasonalWorldReconciler.canWork()) {
                  return false;
               }

               long packed = it.next();
               String encoded = this.removedFlora.get(packed);
               if (encoded == null) {
                  it.remove();
               } else {
                  SeasonalWorldData.DecodedFlora decoded = SeasonalWorldData.decodeFlora(this.chunk, encoded);
                  if (decoded == null) {
                     this.removedFlora.remove(packed);
                     it.remove();
                     this.dirty = true;
                  } else if (FloraSystem.shouldExist(decoded.kind(), decoded.pos(), decoded.state(), frame, seed)) {
                     BlockState current = this.level.getBlockState(decoded.pos());
                     boolean seasonalGroundCover = current.getBlock() == Blocks.SHORT_GRASS;
                     if (!current.isAir() && !seasonalGroundCover) {
                        this.removedFlora.remove(packed);
                        it.remove();
                        this.dirty = true;
                     } else if (decoded.state().canSurvive(this.level, decoded.pos())) {
                        if (!this.trySetFlora(decoded.pos(), decoded.state())) {
                           return false;
                        }

                        SeasonalWorldReconciler.floraRestored++;
                        this.removedFlora.remove(packed);
                        it.remove();
                        this.dirty = true;
                     }
                  }
               }
            }

            if (columnFlora.isEmpty()) {
               this.removedFloraByColumn.remove(columnKey);
            }

            return true;
         }
      }

      private boolean reconcileSeasonFloraInColumn(int lx, int lz, SeasonFrame frame) {
         int wx = (this.chunk.getPos().x() << 4) + lx;
         int wz = (this.chunk.getPos().z() << 4) + lz;
         int top = this.level.getHeight(Types.MOTION_BLOCKING_NO_LEAVES, wx, wz);
         long seed = SeasonEngine.current().visualSeed();

         for (int y = Math.max(this.level.getMinY(), top - 3); y <= Math.min(this.level.getMaxY(), top + 3); y++) {
            if (!SeasonalWorldReconciler.canWork()) {
               return false;
            }

            BlockPos pos = new BlockPos(wx, y, wz);
            BlockState state = this.level.getBlockState(pos);
            if (state.getBlock() != Blocks.SHORT_GRASS) {
               SeasonalFloraKind kind = FloraSystem.kind(state);
               if ((kind == SeasonalFloraKind.FLOWER || kind == SeasonalFloraKind.PLANT
                     || kind == SeasonalFloraKind.MUSHROOM || kind == SeasonalFloraKind.BERRY)
                  && !FloraSystem.shouldExist(kind, pos, state, frame, seed)
                  && !this.removeSeasonalFloraPlant(pos)) {
                  return false;
               }
            }
         }

         return true;
      }

      private BlockPos lowerPlantBase(BlockPos pos) {
         BlockState state = this.level.getBlockState(pos);
         List<BlockPos> parts = FloraSystem.connectedVerticalParts(this.level, pos, state);
         return parts.isEmpty() ? pos : parts.get(0);
      }

      private boolean removeSeasonalFloraPlant(BlockPos pos) {
         BlockState source = this.level.getBlockState(pos);
         if (!FloraSystem.snowReplaceable(source) && FloraSystem.kind(source) == SeasonalFloraKind.NONE) {
            return true;
         } else {
            List<BlockPos> parts = FloraSystem.connectedVerticalParts(this.level, pos, source);

            // All or nothing. Starting a double-height removal without the budget to finish it
            // takes the upper half out and leaves the lower standing headless until some later
            // pass happens to revisit the column.
            if (parts.size() > 1 && SeasonalWorldReconciler.writesRemaining < parts.size()) {
               return false;
            }

            for (BlockPos partPos : parts) {
               BlockState partState = this.level.getBlockState(partPos);
               SeasonalFloraKind partKind = FloraSystem.kind(partState);
               if (partKind != SeasonalFloraKind.NONE || FloraSystem.snowReplaceable(partState)) {
                  if (partKind == SeasonalFloraKind.NONE) {
                     partKind = SeasonalFloraKind.PLANT;
                  }

                  long packed = SeasonalWorldData.packLocal(partPos);
                  if (this.removedFlora.putIfAbsent(packed, SeasonalWorldData.encodeFlora(partKind, partPos, partState)) == null) {
                     index(this.removedFloraByColumn, packed);
                     SeasonalWorldReconciler.floraRemoved++;
                     this.dirty = true;
                  }
               }
            }

            for (int i = parts.size() - 1; i >= 0; i--) {
               BlockPos partPosx = parts.get(i);
               BlockState partState = this.level.getBlockState(partPosx);
               if ((FloraSystem.snowReplaceable(partState) || FloraSystem.kind(partState) != SeasonalFloraKind.NONE)
                  && !this.trySetFlora(partPosx, Blocks.AIR.defaultBlockState())) {
                  return false;
               }
            }

            return true;
         }
      }

      /**
       * The ground cover melting snow leaves behind until Spring restores the real flora.
       *
       * <p>Spring restoration is deliberately gradual - it tracks the plant channel, so at 45%
       * only 45% of a column's canonical flora is back. The placeholder is what keeps the other
       * 55% from reading as bare dirt for most of Spring.
       *
       * <p>Slab terrain needs its own placeholder. {@code minecraft:short_grass} cannot survive on
       * a bottom slab, so on TeslesWorldGeneration's slab ground the vanilla placeholder silently
       * degraded to AIR and those columns stayed visibly bare all Spring while ordinary ground
       * beside them was covered. The slab-mounted proxy is the same plant, mounted the way slab
       * terrain requires.
       */
      private BlockState springGroundCoverState(BlockPos pos) {
         for (BlockState candidate : SeasonalBlockClassifier.groundCoverCandidates()) {
            if (candidate.canSurvive(this.level, pos)) {
               return candidate;
            }
         }

         return Blocks.AIR.defaultBlockState();
      }

      /**
       * Column visiting order for one sweep.
       *
       * <p>Keyed on the sweep number rather than the revision. An odd step modulo 256 makes this a
       * true permutation, so one sweep visits all 256 columns exactly once; re-keying it mid-sweep
       * (as keying on the revision did) reshuffles the mapping and leaves columns unvisited.
       */
      private int permuted(int index, int sweep) {
         return columnOrder(this.chunk.getPos().x(), this.chunk.getPos().z(), index, sweep);
      }

      private static void index(Map<Integer, LinkedHashSet<Long>> index, long packed) {
         int column = SeasonalWorldData.localColumnKey(packed);
         index.computeIfAbsent(column, ignored -> new LinkedHashSet<>()).add(packed);
      }

      private boolean trySetSurface(BlockPos pos, BlockState state) {
         return this.trySetSeasonal(pos, state);
      }

      private boolean trySetLeaf(BlockPos pos, BlockState state) {
         return this.trySetSeasonal(pos, state);
      }

      private boolean trySetFlora(BlockPos pos, BlockState state) {
         return this.trySetSeasonal(pos, state);
      }

      /**
       * A seasonal write, with the LOD store held back only if the write diverges from neutral.
       *
       * <p>The direction is read from the blocks themselves rather than from which helper the
       * caller reached for. That matters because the same helper places snow and melts it, drops a
       * leaf and restores it - and only one of each pair may be kept out of the LOD.
       */
      private boolean trySetSeasonal(BlockPos pos, BlockState state) {
         BlockState before = this.level.getBlockState(pos);
         return SeasonNeutrality.movesAwayFromNeutral(before, state)
            ? VoxyServerMutationGuard.runSuppressingLodDivergence(() -> this.trySet(pos, state))
            : this.trySet(pos, state);
      }

      private boolean trySet(BlockPos pos, BlockState state) {
         BlockState old = this.level.getBlockState(pos);
         if (old.equals(state)) {
            return true;
         } else if (isGrassIdentity(old) && (state == null || state.getBlock() != old.getBlock())) {
            // Season logic never changes grass block identity. Winter appearance comes from
            // snow layers placed on top and from the ground tint, never from swapping
            // grass_block for dirt and back, which would destroy the block the player sees
            // and could not be reversed faithfully.
            return true;
         } else if (!SeasonalWorldReconciler.canWork()) {
            return false;
         } else {
            this.level.setBlock(pos, state, 18);
            SeasonalWorldReconciler.writesRemaining--;
            this.writeCounter++;
            this.writesSinceFlush++;
            return true;
         }
      }

      /**
       * Persists the restore ledger for this chunk as soon as its work slice ends.
       *
       * <p>This deliberately does not wait for a batch of 32 mutations. Block mutations mark
       * the chunk unsaved immediately, so a save or crash in the gap between removing a leaf
       * and writing its ledger entry would leave the world with the leaf gone and no record
       * of what to restore. A few extra metadata writes per tick are much cheaper than
       * permanently losing a tree.
       */
      void flushIfDirty() {
         if (this.dirty) {
            this.flush();
         }
      }

      private static boolean isGrassIdentity(BlockState state) {
         if (state == null || state.isAir()) {
            return false;
         }
         if (state.is(Blocks.GRASS_BLOCK)) {
            return true;
         }
         try {
            Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
            if (id == null) {
               return false;
            }
            String path = id.getPath();
            return path.equals("grass_block") || path.endsWith("_grass_block");
         } catch (Throwable ignored) {
            return false;
         }
      }

      void flush() {
         if (this.dirty) {
            SeasonalWorldData.writeOwnedSnow(this.chunk, this.ownedSnow);
            SeasonalWorldData.writeRemovedLeaves(this.chunk, this.removedLeaves.values());
            SeasonalWorldData.writeRemovedFlora(this.chunk, this.removedFlora.values());
            SeasonalWorldData.writeEffectOwned(this.chunk, this.effectOwned);
            this.chunk.markUnsaved();
            this.dirty = false;
            this.writesSinceFlush = 0;
         }
      }
   }
}
