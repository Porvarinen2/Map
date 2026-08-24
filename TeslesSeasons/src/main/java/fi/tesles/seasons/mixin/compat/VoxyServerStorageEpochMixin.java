package fi.tesles.seasons.mixin.compat;

import java.nio.file.Path;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.ModifyVariable;

@Pseudo
@Mixin(
   targets = {"com.dripps.voxyserver.server.ServerLodEngine"},
   remap = false
)
public abstract class VoxyServerStorageEpochMixin {
   @ModifyVariable(
      method = {"<init>(Ljava/nio/file/Path;)V"},
      at = @At("HEAD"),
      argsOnly = true,
      ordinal = 0,
      remap = false,
      require = 0
   )
   private Path tesles$neutralV9ServerStorage(Path root) {
      return root == null ? null : root.resolve("tesles-seasons-neutral-v9");
   }
}
