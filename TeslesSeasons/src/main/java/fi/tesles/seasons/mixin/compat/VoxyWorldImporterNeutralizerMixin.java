package fi.tesles.seasons.mixin.compat;

import com.mojang.serialization.Codec;
import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.world.SeasonalWorldData;
import java.util.List;
import net.minecraft.core.BlockPos;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.ListTag;
import net.minecraft.nbt.NbtOps;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.PalettedContainer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.ModifyVariable;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.commonImpl.importers.WorldImporter"},
   remap = false
)
public abstract class VoxyWorldImporterNeutralizerMixin {
   @Unique
   private static final ThreadLocal<VoxyWorldImporterNeutralizerMixin.tesles$ImportContext> TESLES_IMPORT = new ThreadLocal<>();

   @Inject(
      method = {"importChunkNBT"},
      at = {@At("HEAD")},
      remap = false,
      require = 0
   )
   private void tesles$captureSeasonAttachments(CompoundTag chunk, int regionX, int regionZ, CallbackInfo ci) {
      TESLES_IMPORT.remove();
      if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.suppressSeasonalVoxyReingest) {
         CompoundTag attachments = (CompoundTag)chunk.getCompound("fabric:attachments").orElse(null);
         if (attachments != null) {
            List<Long> snow = tesles$decodeList(attachments, "teslesseasons:owned_snow_v3", Codec.LONG.listOf());
            List<String> leaves = tesles$decodeList(attachments, "teslesseasons:removed_leaves_v3", Codec.STRING.listOf());
            List<String> flora = tesles$decodeList(attachments, "teslesseasons:removed_flora_v4", Codec.STRING.listOf());
            if (!snow.isEmpty() || !leaves.isEmpty() || !flora.isEmpty()) {
               TESLES_IMPORT.set(new VoxyWorldImporterNeutralizerMixin.tesles$ImportContext(snow, leaves, flora));
            }
         }
      }
   }

   @Inject(
      method = {"importChunkNBT"},
      at = {@At("RETURN")},
      remap = false,
      require = 0
   )
   private void tesles$clearSeasonAttachments(CompoundTag chunk, int regionX, int regionZ, CallbackInfo ci) {
      TESLES_IMPORT.remove();
   }

   @ModifyVariable(
      method = {"importSectionNBT"},
      at = @At("STORE"),
      ordinal = 0,
      remap = false,
      require = 0
   )
   private PalettedContainer<BlockState> tesles$restoreNeutralSection(
      PalettedContainer<BlockState> states, int chunkX, int sectionY, int chunkZ, CompoundTag section
   ) {
      VoxyWorldImporterNeutralizerMixin.tesles$ImportContext context = TESLES_IMPORT.get();
      if (context == null) {
         return states;
      } else {
         for (String encoded : context.removedLeaves()) {
            SeasonalWorldData.DecodedState decoded = SeasonalWorldData.decodeStateAtChunk(chunkX, chunkZ, encoded);
            if (decoded != null && decoded.pos().getY() >> 4 == sectionY) {
               BlockPos pos = decoded.pos();
               states.set(pos.getX() & 15, pos.getY() & 15, pos.getZ() & 15, decoded.state());
            }
         }

         for (String encodedx : context.removedFlora()) {
            SeasonalWorldData.DecodedFlora decoded = SeasonalWorldData.decodeFloraAtChunk(chunkX, chunkZ, encodedx);
            if (decoded != null && decoded.pos().getY() >> 4 == sectionY) {
               BlockPos pos = decoded.pos();
               states.set(pos.getX() & 15, pos.getY() & 15, pos.getZ() & 15, decoded.state());
            }
         }

         return states;
      }
   }

   @Unique
   private static <T> List<T> tesles$decodeList(CompoundTag attachments, String key, Codec<List<T>> codec) {
      try {
         ListTag tag = (ListTag)attachments.getList(key).orElse(null);
         return tag == null ? List.of() : codec.parse(NbtOps.INSTANCE, tag).result().orElse(List.of());
      } catch (Throwable var4) {
         return List.of();
      }
   }

   @Unique
   private record tesles$ImportContext(List<Long> ownedSnow, List<String> removedLeaves, List<String> removedFlora) {
   }
}
