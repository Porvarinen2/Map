package fi.tesles.seasons.world;

import fi.tesles.seasons.SeasonEngine;
import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.api.SeasonSnapshot;
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
         + preSendChunks;
   }

   public static float positionNoise(BlockPos pos, long seed) {
      return SeasonCoordinateField.leaf01(pos, seed);
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
      final Set<Long> ownedSnow = new HashSet<>();
      final Map<Integer, LinkedHashSet<Long>> ownedSnowByColumn = new HashMap<>();
      final Map<Long, String> removedLeaves = new HashMap<>();
      final Map<Long, String> removedFlora = new HashMap<>();
      final Map<Integer, LinkedHashSet<Long>> removedLeavesByColumn = new HashMap<>();
      final Map<Integer, LinkedHashSet<Long>> removedFloraByColumn = new HashMap<>();
      int surfaceCursor;
      int leafCursor;
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
         if (this.surfaceRevision != targetSurfaceRevision || this.surfaceCursor < 256) {
            long oldDeadline = SeasonalWorldReconciler.deadlineNanos;
            int oldWrites = SeasonalWorldReconciler.writesRemaining;
            SeasonalWorldReconciler.deadlineNanos = Long.MAX_VALUE;
            SeasonalWorldReconciler.writesRemaining = 536870911;

            try {
               for (int column = 0; column < 256; column++) {
                  this.processSurfaceColumn(column, frame);
               }

               this.surfaceRevision = targetSurfaceRevision;
               this.surfaceCursor = 256;
               this.flush();
            } finally {
               SeasonalWorldReconciler.deadlineNanos = oldDeadline;
               SeasonalWorldReconciler.writesRemaining = oldWrites;
            }
         }
      }

      void canonicalizeVisibleBeforeSend(SeasonFrame frame) {
         long oldDeadline = SeasonalWorldReconciler.deadlineNanos;
         int oldWrites = SeasonalWorldReconciler.writesRemaining;
         SeasonalWorldReconciler.deadlineNanos = Long.MAX_VALUE;
         SeasonalWorldReconciler.writesRemaining = 536870911;

         try {
            int targetSurfaceRevision = SeasonalWorldReconciler.surfaceRevision(frame);
            if (this.surfaceRevision != targetSurfaceRevision || this.surfaceCursor < 256) {
               for (int column = 0; column < 256; column++) {
                  this.processSurfaceColumn(column, frame);
               }

               this.surfaceRevision = targetSurfaceRevision;
               this.surfaceCursor = 256;
            }

            this.restoreEligibleLeavesFromMetadata(frame);
            int targetLeafRevision = SeasonalWorldReconciler.leafRevision(frame);
            if (this.leafRevision != targetLeafRevision || this.leafCursor < 256) {
               for (int column = 0; column < 256; column++) {
                  this.processLeafColumn(column, frame);
               }

               this.leafRevision = targetLeafRevision;
               this.leafCursor = 256;
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

      int processSurface(SeasonFrame frame, int count) {
         int rev = SeasonalWorldReconciler.surfaceRevision(frame);
         if (this.surfaceRevision != rev) {
            this.surfaceRevision = rev;
            this.surfaceCursor = 0;
         }

         int done;
         for (done = 0; done < count && this.surfaceCursor < 256 && SeasonalWorldReconciler.canWork(); done++) {
            int column = this.permuted(this.surfaceCursor, this.surfaceRevision);
            if (!this.processSurfaceColumn(column, frame)) {
               break;
            }

            this.surfaceCursor++;
         }

         SeasonalWorldReconciler.surfaceColumnsProcessed += done;
         return done;
      }

      int processLeaves(SeasonFrame frame, int count) {
         int rev = SeasonalWorldReconciler.leafRevision(frame);
         if (this.leafRevision != rev) {
            this.leafRevision = rev;
            this.leafCursor = 0;
         }

         int done;
         for (done = 0; done < count && this.leafCursor < 256 && SeasonalWorldReconciler.canWork(); done++) {
            int column = this.permuted(this.leafCursor, this.leafRevision);
            if (!this.processLeafColumn(column, frame)) {
               break;
            }

            this.leafCursor++;
         }

         SeasonalWorldReconciler.leafColumnsProcessed += done;
         return done;
      }

      private boolean processSurfaceColumn(int column, SeasonFrame frame) {
         int lx = column & 15;
         int lz = column >>> 4 & 15;
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

            return this.reconcileSeasonFloraInColumn(lx, lz, frame);
         }
      }

      private boolean processLeafColumn(int column, SeasonFrame frame) {
         int lx = column & 15;
         int lz = column >>> 4 & 15;
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
               if ((kind == SeasonalFloraKind.FLOWER || kind == SeasonalFloraKind.PLANT || kind == SeasonalFloraKind.MUSHROOM)
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

      private BlockState springGroundCoverState(BlockPos pos) {
         BlockState grass = Blocks.SHORT_GRASS.defaultBlockState();
         return grass.canSurvive(this.level, pos) ? grass : Blocks.AIR.defaultBlockState();
      }

      private int permuted(int index, int revision) {
         int seed = this.chunk.getPos().x() * 73428767 ^ this.chunk.getPos().z() * 912931 ^ revision;
         int start = seed & 0xFF;
         int step = (seed >>> 8 | 1) & 0xFF;
         if (step == 0) {
            step = 73;
         }

         return start + index * step & 0xFF;
      }

      private static void index(Map<Integer, LinkedHashSet<Long>> index, long packed) {
         int column = SeasonalWorldData.localColumnKey(packed);
         index.computeIfAbsent(column, ignored -> new LinkedHashSet<>()).add(packed);
      }

      private boolean trySetSurface(BlockPos pos, BlockState state) {
         return VoxyServerMutationGuard.runSuppressingTransientSurfaceMutation(() -> this.trySet(pos, state));
      }

      private boolean trySetLeaf(BlockPos pos, BlockState state) {
         return VoxyServerMutationGuard.runSuppressingLeafRemoval(() -> this.trySet(pos, state));
      }

      private boolean trySetFlora(BlockPos pos, BlockState state) {
         return VoxyServerMutationGuard.runSuppressingFloraRemoval(() -> this.trySet(pos, state));
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
            this.chunk.markUnsaved();
            this.dirty = false;
            this.writesSinceFlush = 0;
         }
      }
   }
}
