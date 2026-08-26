package fi.tesles.seasons.world;

import com.mojang.serialization.Codec;
import fi.tesles.seasons.TeslesSeasons;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.List;
import net.fabricmc.fabric.api.attachment.v1.AttachmentRegistry;
import net.fabricmc.fabric.api.attachment.v1.AttachmentType;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.Property;
import net.minecraft.world.level.chunk.LevelChunk;

public final class SeasonalWorldData {
   public static final AttachmentType<List<Long>> OWNED_SNOW = AttachmentRegistry.createPersistent(TeslesSeasons.id("owned_snow_v3"), Codec.LONG.listOf());
   public static final AttachmentType<List<String>> REMOVED_LEAVES = AttachmentRegistry.createPersistent(
      TeslesSeasons.id("removed_leaves_v3"), Codec.STRING.listOf()
   );
   public static final AttachmentType<List<String>> REMOVED_FLORA = AttachmentRegistry.createPersistent(
      TeslesSeasons.id("removed_flora_v4"), Codec.STRING.listOf()
   );
   /**
    * Positions owned by pluggable world effects, keyed by effect id.
    *
    * <p>One attachment for all of them rather than one per effect, so adding an effect needs no
    * new registration and no migration: an effect that has never run simply has no entry. The
    * built-in snow ledger stays separate because it predates this and is read by the Voxy
    * neutraliser by name.
    */
   public static final AttachmentType<Map<String, List<Long>>> EFFECT_OWNED = AttachmentRegistry.createPersistent(
      TeslesSeasons.id("effect_owned_v1"), Codec.unboundedMap(Codec.STRING, Codec.LONG.listOf())
   );

   public static final AttachmentType<Boolean> LEGACY_022_SNOW_MIGRATED = AttachmentRegistry.createPersistent(
      TeslesSeasons.id("legacy_022_snow_migrated"), Codec.BOOL
   );

   private SeasonalWorldData() {
   }

   public static void init() {
   }

   public static List<Long> readOwnedSnow(LevelChunk chunk) {
      List<Long> value = (List<Long>)chunk.getAttached(OWNED_SNOW);
      return value == null ? Collections.emptyList() : value;
   }

   public static void writeOwnedSnow(LevelChunk chunk, Iterable<Long> packed) {
      ArrayList<Long> copy = new ArrayList<>();

      for (Long value : packed) {
         copy.add(value);
      }

      if (copy.isEmpty()) {
         chunk.removeAttached(OWNED_SNOW);
      } else {
         chunk.setAttached(OWNED_SNOW, List.copyOf(copy));
      }
   }

   public static List<String> readRemovedLeaves(LevelChunk chunk) {
      List<String> value = (List<String>)chunk.getAttached(REMOVED_LEAVES);
      return value == null ? Collections.emptyList() : value;
   }

   public static void writeRemovedLeaves(LevelChunk chunk, Iterable<String> encoded) {
      ArrayList<String> copy = new ArrayList<>();

      for (String value : encoded) {
         copy.add(value);
      }

      if (copy.isEmpty()) {
         chunk.removeAttached(REMOVED_LEAVES);
      } else {
         chunk.setAttached(REMOVED_LEAVES, List.copyOf(copy));
      }
   }

   public static List<String> readRemovedFlora(LevelChunk chunk) {
      List<String> value = (List<String>)chunk.getAttached(REMOVED_FLORA);
      return value == null ? Collections.emptyList() : value;
   }

   public static void writeRemovedFlora(LevelChunk chunk, Iterable<String> encoded) {
      ArrayList<String> copy = new ArrayList<>();

      for (String value : encoded) {
         copy.add(value);
      }

      if (copy.isEmpty()) {
         chunk.removeAttached(REMOVED_FLORA);
      } else {
         chunk.setAttached(REMOVED_FLORA, List.copyOf(copy));
      }
   }

   public static boolean legacyMigrated(LevelChunk chunk) {
      return Boolean.TRUE.equals(chunk.getAttached(LEGACY_022_SNOW_MIGRATED));
   }

   public static void markLegacyMigrated(LevelChunk chunk) {
      chunk.setAttached(LEGACY_022_SNOW_MIGRATED, true);
   }

   public static Map<String, List<Long>> readEffectOwned(LevelChunk chunk) {
      Map<String, List<Long>> value = chunk.getAttached(EFFECT_OWNED);
      return value == null ? Map.of() : value;
   }

   public static void writeEffectOwned(LevelChunk chunk, Map<String, ? extends Collection<Long>> owned) {
      if (owned == null || owned.isEmpty()) {
         chunk.removeAttached(EFFECT_OWNED);
         return;
      }

      Map<String, List<Long>> out = new LinkedHashMap<>(owned.size());
      for (Map.Entry<String, ? extends Collection<Long>> entry : owned.entrySet()) {
         if (!entry.getValue().isEmpty()) {
            out.put(entry.getKey(), List.copyOf(entry.getValue()));
         }
      }

      if (out.isEmpty()) {
         chunk.removeAttached(EFFECT_OWNED);
      } else {
         chunk.setAttached(EFFECT_OWNED, out);
      }
   }

   public static long packLocal(BlockPos pos) {
      return (long)pos.getY() << 8 | (long)(pos.getZ() & 15) << 4 | pos.getX() & 15;
   }

   public static BlockPos unpackLocal(LevelChunk chunk, long packed) {
      int x = chunk.getPos().getMinBlockX() + (int)(packed & 15L);
      int z = chunk.getPos().getMinBlockZ() + (int)(packed >>> 4 & 15L);
      int y = (int)(packed >> 8);
      return new BlockPos(x, y, z);
   }

   public static BlockPos unpackLocal(int chunkX, int chunkZ, long packed) {
      int x = (chunkX << 4) + (int)(packed & 15L);
      int z = (chunkZ << 4) + (int)(packed >>> 4 & 15L);
      int y = (int)(packed >> 8);
      return new BlockPos(x, y, z);
   }

   public static int localColumnKey(long packed) {
      return (int)(packed & 255L);
   }

   public static String encodeState(BlockPos pos, BlockState state) {
      Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
      if (id == null) {
         return null;
      } else {
         StringBuilder out = new StringBuilder();
         out.append(packLocal(pos)).append('|').append(id);

         for (Property<?> property : state.getProperties()) {
            out.append('|').append(property.getName()).append('=').append(propertyValueName(state, property));
         }

         return out.toString();
      }
   }

   public static String encodeFlora(SeasonalFloraKind kind, BlockPos pos, BlockState state) {
      String encodedState = encodeState(pos, state);
      return encodedState == null ? null : kind.name() + "|" + encodedState;
   }

   public static long encodedFloraPackedPos(String encoded) {
      if (encoded == null) {
         return Long.MIN_VALUE;
      } else {
         int split = encoded.indexOf(124);
         return split > 0 && split < encoded.length() - 1 ? encodedPackedPos(encoded.substring(split + 1)) : Long.MIN_VALUE;
      }
   }

   public static SeasonalWorldData.DecodedFlora decodeFlora(LevelChunk chunk, String encoded) {
      if (encoded == null) {
         return null;
      } else {
         int split = encoded.indexOf(124);
         if (split > 0 && split < encoded.length() - 1) {
            SeasonalFloraKind kind;
            try {
               kind = SeasonalFloraKind.valueOf(encoded.substring(0, split));
            } catch (IllegalArgumentException var5) {
               return null;
            }

            SeasonalWorldData.DecodedState state = decodeState(chunk, encoded.substring(split + 1));
            return state == null ? null : new SeasonalWorldData.DecodedFlora(kind, state.pos(), state.state(), encoded);
         } else {
            return null;
         }
      }
   }

   public static SeasonalWorldData.DecodedFlora decodeFloraAtChunk(int chunkX, int chunkZ, String encoded) {
      if (encoded == null) {
         return null;
      } else {
         int split = encoded.indexOf(124);
         if (split > 0 && split < encoded.length() - 1) {
            SeasonalFloraKind kind;
            try {
               kind = SeasonalFloraKind.valueOf(encoded.substring(0, split));
            } catch (IllegalArgumentException var6) {
               return null;
            }

            SeasonalWorldData.DecodedState state = decodeStateAtChunk(chunkX, chunkZ, encoded.substring(split + 1));
            return state == null ? null : new SeasonalWorldData.DecodedFlora(kind, state.pos(), state.state(), encoded);
         } else {
            return null;
         }
      }
   }

   public static long encodedPackedPos(String encoded) {
      if (encoded == null) {
         return Long.MIN_VALUE;
      } else {
         int split = encoded.indexOf(124);
         if (split <= 0) {
            return Long.MIN_VALUE;
         } else {
            try {
               return Long.parseLong(encoded.substring(0, split));
            } catch (NumberFormatException var3) {
               return Long.MIN_VALUE;
            }
         }
      }
   }

   public static SeasonalWorldData.DecodedState decodeState(LevelChunk chunk, String encoded) {
      return decodeStateAtChunk(chunk.getPos().x(), chunk.getPos().z(), encoded);
   }

   public static SeasonalWorldData.DecodedState decodeStateAtChunk(int chunkX, int chunkZ, String encoded) {
      if (encoded != null && !encoded.isBlank()) {
         String[] pieces = encoded.split("\\|");
         if (pieces.length < 2) {
            return null;
         } else {
            long packed;
            try {
               packed = Long.parseLong(pieces[0]);
            } catch (NumberFormatException var12) {
               return null;
            }

            Identifier id;
            try {
               id = Identifier.parse(pieces[1]);
            } catch (Exception var11) {
               return null;
            }

            Block block = (Block)BuiltInRegistries.BLOCK.getValue(id);
            if (block == null) {
               return null;
            } else if (block == Blocks.AIR && !id.equals(BuiltInRegistries.BLOCK.getKey(Blocks.AIR))) {
               return null;
            } else {
               BlockState state = block.defaultBlockState();

               for (int i = 2; i < pieces.length; i++) {
                  int equals = pieces[i].indexOf(61);
                  if (equals > 0 && equals < pieces[i].length() - 1) {
                     state = applyProperty(state, pieces[i].substring(0, equals), pieces[i].substring(equals + 1));
                  }
               }

               return new SeasonalWorldData.DecodedState(unpackLocal(chunkX, chunkZ, packed), state, encoded);
            }
         }
      } else {
         return null;
      }
   }

   private static <T extends Comparable<T>> String propertyValueName(BlockState state, Property<T> property) {
      return property.getName(state.getValue(property));
   }

   private static BlockState applyProperty(BlockState state, String propertyName, String raw) {
      for (Property<?> property : state.getProperties()) {
         if (property.getName().equals(propertyName)) {
            return applyPropertyValue(state, property, raw);
         }
      }

      return state;
   }

   private static <T extends Comparable<T>> BlockState applyPropertyValue(BlockState state, Property<T> property, String raw) {
      return property.getValue(raw).map(value -> (BlockState)state.setValue(property, value)).orElse(state);
   }

   public record DecodedFlora(SeasonalFloraKind kind, BlockPos pos, BlockState state, String encoded) {
   }

   public record DecodedState(BlockPos pos, BlockState state, String encoded) {
   }
}
