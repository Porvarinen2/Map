package fi.tesles.seasons.mixin.fix062;

import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.Constant;
import org.spongepowered.asm.mixin.injection.ModifyConstant;

@Pseudo
@Mixin(
   targets = {"fi.tesles.seasons.compat.VoxyServerBackfillBridge"},
   remap = false
)
public abstract class VoxyBackfillEpochMixin {
   @ModifyConstant(
      method = {"tryInitialize()V"},
      constant = {@Constant(
         stringValue = "voxyserver-existing-overworld-backfill-v3.done"
      )},
      remap = false,
      require = 0
   )
   private static String tesles$useV9NeutralBackfillMarker(String original) {
      return "voxyserver-existing-overworld-backfill-v9.done";
   }
}
