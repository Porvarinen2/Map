package fi.tesles.seasons.mixin.fix061;

import com.mojang.serialization.Codec;
import fi.tesles.seasons.fix061.VoxyNeutralSnapshot;
import fi.tesles.seasons.world.SeasonalWorldData;
import java.util.List;
import net.minecraft.core.BlockPos;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.ListTag;
import net.minecraft.nbt.NbtOps;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.SnowyBlock;
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
public abstract class VoxyImporterSnowNeutralizerFixMixin {
   @Unique
   private static final ThreadLocal<List<Long>> TESLES$OWNED_SNOW = new ThreadLocal<>();

   @Inject(
      method = {"importChunkNBT"},
      at = {@At("HEAD")},
      remap = false,
      require = 0
   )
   private void tesles$captureOwnedSnow(CompoundTag chunkTag, int regionX, int regionZ, CallbackInfo ci) {
      TESLES$OWNED_SNOW.remove();

      try {
         CompoundTag attachments = (CompoundTag)chunkTag.getCompound("fabric:attachments").orElse(null);
         if (attachments == null) {
            return;
         }

         List<Long> owned = tesles$decodeLongList(attachments, "teslesseasons:owned_snow_v3");
         if (!owned.isEmpty()) {
            TESLES$OWNED_SNOW.set(owned);
         }
      } catch (Throwable var7) {
         VoxyNeutralSnapshot.FAILURES.incrementAndGet();
      }
   }

   @Inject(
      method = {"importChunkNBT"},
      at = {@At("RETURN")},
      remap = false,
      require = 0
   )
   private void tesles$clearOwnedSnow(CompoundTag chunkTag, int regionX, int regionZ, CallbackInfo ci) {
      TESLES$OWNED_SNOW.remove();
   }

   @ModifyVariable(
      method = {"importSectionNBT"},
      at = @At("STORE"),
      ordinal = 0,
      remap = false,
      require = 0
   )
   private PalettedContainer<BlockState> tesles$neutralizeOwnedSnow(
      PalettedContainer<BlockState> states, int chunkX, int sectionY, int chunkZ, CompoundTag sectionTag
   ) {
      List<Long> owned = TESLES$OWNED_SNOW.get();
      if (owned != null && !owned.isEmpty()) {
         try {
            for (long packed : owned) {
               BlockPos snowPos = SeasonalWorldData.unpackLocal(chunkX, chunkZ, packed);
               if (snowPos.getY() >> 4 == sectionY) {
                  int x = snowPos.getX() & 15;
                  int y = snowPos.getY() & 15;
                  int z = snowPos.getZ() & 15;
                  BlockState current = (BlockState)states.get(x, y, z);
                  if (VoxyNeutralSnapshot.isSeasonSnow(current)) {
                     states.set(x, y, z, Blocks.AIR.defaultBlockState());
                     VoxyNeutralSnapshot.STRIPPED_SNOW.incrementAndGet();
                  }
               }

               BlockPos basePos = snowPos.below();
               if (basePos.getY() >> 4 == sectionY) {
                  int x = basePos.getX() & 15;
                  int y = basePos.getY() & 15;
                  int z = basePos.getZ() & 15;
                  BlockState base = (BlockState)states.get(x, y, z);
                  if (base.hasProperty(SnowyBlock.SNOWY) && Boolean.TRUE.equals(base.getValue(SnowyBlock.SNOWY))) {
                     states.set(x, y, z, (BlockState)base.setValue(SnowyBlock.SNOWY, false));
                  }
               }
            }
         } catch (Throwable var16) {
            VoxyNeutralSnapshot.FAILURES.incrementAndGet();
         }

         return states;
      } else {
         return states;
      }
   }

   @Unique
   private static List<Long> tesles$decodeLongList(CompoundTag attachments, String key) {
      try {
         ListTag tag = (ListTag)attachments.getList(key).orElse(null);
         return tag == null ? List.of() : Codec.LONG.listOf().parse(NbtOps.INSTANCE, tag).result().orElse(List.of());
      } catch (Throwable var3) {
         return List.of();
      }
   }
}
