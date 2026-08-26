package fi.tesles.seasons.mixin.compat;

import com.mojang.serialization.Codec;
import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.world.SeasonalWorldData;
import fi.tesles.seasons.world.system.SnowSystem;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.SnowyBlock;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.NbtOps;
import net.minecraft.nbt.Tag;
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
   @Unique
   private static final AtomicLong tesles$strippedSnow = new AtomicLong();
   @Unique
   private static final AtomicLong tesles$restoredLeaves = new AtomicLong();
   @Unique
   private static final AtomicLong tesles$restoredFlora = new AtomicLong();
   @Unique
   private static final AtomicLong tesles$reported = new AtomicLong();

   /**
    * Says out loud that the import is being neutralised, and roughly how much of it.
    *
    * <p>This injection is declared {@code require = 0}, so if Voxy ever renames the importer it
    * stops applying without failing the build or the game - and a rebuilt LOD store would then
    * quietly carry whatever season the region files were saved in. A line in the log is what
    * distinguishes "ran and found nothing" from "never ran".
    */
   @Unique
   private static void tesles$reportProgress() {
      long snow = tesles$strippedSnow.get();
      long leaves = tesles$restoredLeaves.get();
      long flora = tesles$restoredFlora.get();
      long total = snow + leaves + flora;
      long milestone = tesles$reported.get();
      if (total >= milestone + 50000L && tesles$reported.compareAndSet(milestone, total)) {
         TeslesSeasons.LOGGER.info(
            "TESLES neutralising imported Voxy LOD: {} seasonal snow removed, {} leaves restored, {} flora restored.",
            snow, leaves, flora
         );
      }
   }

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
         // Seasonal snow, taken back out. The chunk's owned-snow ledger was already being read
         // here and then never applied, so an imported LOD kept whatever winter the region files
         // happened to be saved in - which is the half of a rebuilt store that stayed wrong even
         // after the canopy came back.
         for (long packed : context.ownedSnow()) {
            BlockPos pos = SeasonalWorldData.unpackLocal(chunkX, chunkZ, packed);
            if (pos.getY() >> 4 != sectionY) {
               continue;
            }

            int lx = pos.getX() & 15;
            int ly = pos.getY() & 15;
            int lz = pos.getZ() & 15;
            if (SnowSystem.isSnowLayer(states.get(lx, ly, lz))) {
               states.set(lx, ly, lz, Blocks.AIR.defaultBlockState());
               tesles$strippedSnow.incrementAndGet();
            }

            // Grass remembers whether it was under snow. Left set, the ground below imports as the
            // darkened snowy variant with nothing on top of it.
            if (ly > 0) {
               BlockState base = states.get(lx, ly - 1, lz);
               if (base.hasProperty(SnowyBlock.SNOWY) && Boolean.TRUE.equals(base.getValue(SnowyBlock.SNOWY))) {
                  states.set(lx, ly - 1, lz, base.setValue(SnowyBlock.SNOWY, false));
               }
            }
         }

         for (String encoded : context.removedLeaves()) {
            SeasonalWorldData.DecodedState decoded = SeasonalWorldData.decodeStateAtChunk(chunkX, chunkZ, encoded);
            if (decoded != null && decoded.pos().getY() >> 4 == sectionY) {
               BlockPos pos = decoded.pos();
               states.set(pos.getX() & 15, pos.getY() & 15, pos.getZ() & 15, decoded.state());
               tesles$restoredLeaves.incrementAndGet();
            }
         }

         for (String encodedx : context.removedFlora()) {
            SeasonalWorldData.DecodedFlora decoded = SeasonalWorldData.decodeFloraAtChunk(chunkX, chunkZ, encodedx);
            if (decoded != null && decoded.pos().getY() >> 4 == sectionY) {
               BlockPos pos = decoded.pos();
               states.set(pos.getX() & 15, pos.getY() & 15, pos.getZ() & 15, decoded.state());
               tesles$restoredFlora.incrementAndGet();
            }
         }

         tesles$reportProgress();
         return states;
      }
   }

   /**
    * Reads one persisted attachment list out of a chunk's NBT.
    *
    * <p>Both tag shapes have to be accepted. NbtOps collapses a list of longs into a
    * {@code LongArrayTag} rather than leaving it a {@code ListTag}, so the owned-snow ledger - the
    * one keyed by packed position - is stored under a different tag type than the leaf and flora
    * ledgers, which are lists of strings. Asking only for the list shape silently returned nothing
    * for snow, and an imported LOD kept its winter.
    */
   @Unique
   private static <T> List<T> tesles$decodeList(CompoundTag attachments, String key, Codec<List<T>> codec) {
      try {
         Tag tag = attachments.get(key);
         return tag == null ? List.of() : codec.parse(NbtOps.INSTANCE, tag).result().orElse(List.of());
      } catch (Throwable ignored) {
         return List.of();
      }
   }

   @Unique
   private record tesles$ImportContext(List<Long> ownedSnow, List<String> removedLeaves, List<String> removedFlora) {
   }
}
