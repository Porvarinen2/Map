package fi.tesles.seasons.mixin.fix064;

import fi.tesles.seasons.TeslesSeasonsConfig;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(
   targets = {"fi.tesles.seasons.TeslesSeasonsConfig"},
   remap = false
)
public abstract class SeasonSchedulerConfigMixin {
   @Inject(
      method = {"load()Lfi/tesles/seasons/TeslesSeasonsConfig;"},
      at = {@At("RETURN")},
      remap = false,
      require = 1
   )
   private static void tesles$proportionalSafety(CallbackInfoReturnable<TeslesSeasonsConfig> cir) {
      TeslesSeasonsConfig config = (TeslesSeasonsConfig)cir.getReturnValue();
      if (config != null) {
         config.plantSnowOverlay = false;
         config.nearVegetationFlattening = false;
         config.maximumGroundPlantFlattening = 0.0;
         config.seasonalSnow = true;
         config.maximumPhysicalSnowCoverage = 1.0;
         config.maximumAccumulatedSnowLayers = 8;
         config.winterSnowReplacesWildFlora = true;
         config.physicalDeciduousLeafFall = true;
         config.minimumWinterLeafRetention = 0.0;
         config.protectDormantDynamicTreeBranches = true;
         config.suppressDormantDynamicTreeLeafSpread = true;
         config.preSendSeasonProjection = true;
         config.materializationSteps = 100;
      }
   }
}
