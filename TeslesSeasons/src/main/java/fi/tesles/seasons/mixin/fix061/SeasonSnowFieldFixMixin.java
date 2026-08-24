package fi.tesles.seasons.mixin.fix061;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.fix061.OrganicSnowField;
import fi.tesles.seasons.fix069.ProportionalSeasonModel;
import net.minecraft.server.level.ServerLevel;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(
   targets = {"fi.tesles.seasons.world.SeasonalWorldReconciler"},
   remap = false
)
public abstract class SeasonSnowFieldFixMixin {
   @Inject(
      method = {"snowCoverageNoise(IIJ)D"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$organicCoverage(int blockX, int blockZ, long visualSeed, CallbackInfoReturnable<Double> cir) {
      cir.setReturnValue(OrganicSnowField.coverageNoise(blockX, blockZ, visualSeed));
   }

   @Inject(
      method = {"wantsSnowHere(Lfi/tesles/seasons/api/SeasonSnapshot;DD)Z"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$phaseCoverage(SeasonSnapshot snapshot, double mappedCoverage, double noise, CallbackInfoReturnable<Boolean> cir) {
      cir.setReturnValue(OrganicSnowField.wantsSnow(ProportionalSeasonModel.snowCoverage(snapshot), noise));
   }

   @Inject(
      method = {"desiredSnowLayers(Lfi/tesles/seasons/api/SeasonSnapshot;Lnet/minecraft/server/level/ServerLevel;II)I"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$literalSnowDepth(SeasonSnapshot snapshot, ServerLevel level, int blockX, int blockZ, CallbackInfoReturnable<Integer> cir) {
      cir.setReturnValue(ProportionalSeasonModel.snowLayersAt(snapshot, blockX, blockZ));
   }

   @Inject(
      method = {"desiredSnowPeakLayers(Lfi/tesles/seasons/api/SeasonSnapshot;)I"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$literalPeak(SeasonSnapshot snapshot, CallbackInfoReturnable<Integer> cir) {
      cir.setReturnValue(ProportionalSeasonModel.baseSnowLayers(snapshot));
   }

   @Inject(
      method = {"seasonalBaseSnowLayers(Lfi/tesles/seasons/api/SeasonSnapshot;I)I"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$literalBase(SeasonSnapshot snapshot, int maxLayers, CallbackInfoReturnable<Integer> cir) {
      cir.setReturnValue(Math.min(Math.max(0, maxLayers), ProportionalSeasonModel.baseSnowLayers(snapshot)));
   }

   @Inject(
      method = {"surfaceRevision(Lfi/tesles/seasons/api/SeasonSnapshot;)I"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$revisionIncludesDepth(SeasonSnapshot snapshot, CallbackInfoReturnable<Integer> cir) {
      int steps = TeslesSeasons.CONFIG == null ? 24 : TeslesSeasons.CONFIG.materializationSteps;
      cir.setReturnValue(ProportionalSeasonModel.surfaceRevision(snapshot, steps));
   }
}
