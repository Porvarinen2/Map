package fi.tesles.seasons.fix064;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.world.SeasonalWorldReconciler;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.chunk.LevelChunk;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class EndpointChannelCanonicalizer {
   private static final Logger LOGGER = LoggerFactory.getLogger("TeslesSeasons/EndpointCanonicalizer");
   private static final Object INIT_LOCK = new Object();
   private static volatile EndpointChannelCanonicalizer.Access ACCESS;
   private static volatile boolean failed;
   private static final ArrayDeque<Long> SURFACE_ENDPOINT_SWEEP = new ArrayDeque<>();
   private static final ArrayDeque<Long> LEAF_ENDPOINT_SWEEP = new ArrayDeque<>();
   private static int surfaceEndpointToken = -1;
   private static int leafEndpointToken = -1;

   private EndpointChannelCanonicalizer() {
   }

   public static void prioritizeLoadedChunk(ServerLevel level, LevelChunk chunk, SeasonSnapshot snapshot) {
      if (level != null && chunk != null && snapshot != null && !failed) {
         try {
            EndpointChannelCanonicalizer.Access a = access();
            if (a == null) {
               return;
            }

            long key = key(chunk);
            if (!a.loaded.containsKey(key)) {
               return;
            }

            a.enqueueSurface.invoke(null, key, true);
            a.enqueueLeaves.invoke(null, key, true);
         } catch (Throwable var6) {
            failed = true;
            LOGGER.error("TESLES current-phase chunk queue promotion failed; disabling adapter", var6);
         }
      }
   }

   public static void sweepLoadedEndpoints(SeasonSnapshot snapshot, int promotionsPerChannel) {
      if (snapshot != null && promotionsPerChannel > 0 && !failed) {
         try {
            EndpointChannelCanonicalizer.Access a = access();
            if (a == null) {
               return;
            }

            boolean surface = isSurfaceEndpoint(snapshot);
            boolean leaf = isLeafEndpoint(snapshot);
            int newSurfaceToken = surface ? (snapshot.snowCover() >= 0.5F ? 1 : 0) : -1;
            int newLeafToken = leaf ? (snapshot.leafRetention() >= 0.5F ? 1 : 0) : -1;
            synchronized (INIT_LOCK) {
               if (!surface) {
                  surfaceEndpointToken = -1;
                  SURFACE_ENDPOINT_SWEEP.clear();
               } else if (newSurfaceToken != surfaceEndpointToken) {
                  surfaceEndpointToken = newSurfaceToken;
                  refillShuffled(SURFACE_ENDPOINT_SWEEP, a.loaded.keySet(), snapshot.visualSeed() ^ 85614317L);
               }

               if (!leaf) {
                  leafEndpointToken = -1;
                  LEAF_ENDPOINT_SWEEP.clear();
               } else if (newLeafToken != leafEndpointToken) {
                  leafEndpointToken = newLeafToken;
                  refillShuffled(LEAF_ENDPOINT_SWEEP, a.loaded.keySet(), snapshot.visualSeed() ^ 514834159L);
               }

               for (int i = 0; i < promotionsPerChannel && surface && !SURFACE_ENDPOINT_SWEEP.isEmpty(); i++) {
                  long key = SURFACE_ENDPOINT_SWEEP.removeFirst();
                  if (a.loaded.containsKey(key)) {
                     a.enqueueSurface.invoke(null, key, true);
                  }
               }

               for (int ix = 0; ix < promotionsPerChannel && leaf && !LEAF_ENDPOINT_SWEEP.isEmpty(); ix++) {
                  long key = LEAF_ENDPOINT_SWEEP.removeFirst();
                  if (a.loaded.containsKey(key)) {
                     a.enqueueLeaves.invoke(null, key, true);
                  }
               }
            }
         } catch (Throwable var13) {
            failed = true;
            LOGGER.error("TESLES loaded endpoint queue sweep failed; disabling endpoint adapter", var13);
         }
      }
   }

   private static void refillShuffled(ArrayDeque<Long> target, Set<Long> keys, long seed) {
      target.clear();
      ArrayList<Long> shuffled = new ArrayList<>(keys);
      Collections.shuffle(shuffled, new Random(seed));
      target.addAll(shuffled);
   }

   public static boolean isSurfaceEndpoint(SeasonSnapshot s) {
      float snow = clamp01(s.snowCover());
      return (snow <= 0.005F || snow >= 0.995F) && !s.snowAccumulating() && !s.snowThawing();
   }

   public static boolean isLeafEndpoint(SeasonSnapshot s) {
      float leaf = clamp01(s.leafRetention());
      return leaf <= 0.001F || leaf >= 0.999F;
   }

   private static EndpointChannelCanonicalizer.Access access() throws ReflectiveOperationException {
      EndpointChannelCanonicalizer.Access value = ACCESS;
      if (value != null) {
         return value;
      } else {
         synchronized (INIT_LOCK) {
            value = ACCESS;
            if (value != null) {
               return value;
            } else {
               Class<?> reconciler = SeasonalWorldReconciler.class;
               Field loadedField = reconciler.getDeclaredField("LOADED");
               loadedField.setAccessible(true);
               Map<Long, Object> loaded = (Map<Long, Object>)loadedField.get(null);
               Method enqueueSurface = declared(reconciler, "enqueueSurface", long.class, boolean.class);
               Method enqueueLeaves = declared(reconciler, "enqueueLeaves", long.class, boolean.class);
               value = new EndpointChannelCanonicalizer.Access(loaded, enqueueSurface, enqueueLeaves);
               ACCESS = value;
               return value;
            }
         }
      }
   }

   private static Method declared(Class<?> owner, String name, Class<?>... args) throws ReflectiveOperationException {
      Method method = owner.getDeclaredMethod(name, args);
      method.setAccessible(true);
      return method;
   }

   private static long key(LevelChunk chunk) {
      return Integer.toUnsignedLong(chunk.getPos().x()) | Integer.toUnsignedLong(chunk.getPos().z()) << 32;
   }

   private static float clamp01(float value) {
      return Math.max(0.0F, Math.min(1.0F, value));
   }

   private record Access(Map<Long, Object> loaded, Method enqueueSurface, Method enqueueLeaves) {
   }
}
