package fi.tesles.seasons.world.system;

import net.minecraft.core.BlockPos;

public final class SeasonCoordinateField {
   public static final int SNOW_COVERAGE_SALT = 1779033703;
   public static final int SNOW_DEPTH_SALT = -1150833019;
   public static final int FLORA_SALT = 608135816;

   private SeasonCoordinateField() {
   }

   public static float snowCoverage01(int x, int z, long seed) {
      return hash2D(x, z, seed, 1779033703);
   }

   public static float snowDepth01(int x, int z, long seed) {
      return hash2D(x, z, seed, -1150833019);
   }

   public static float leaf01(BlockPos pos, long seed) {
      int h = pos.getX() * -1640531527 ^ pos.getY() * -2048144789 ^ pos.getZ() * -1028477387 ^ (int)seed;
      return mixToUnit(h);
   }

   public static float flora01(BlockPos pos, long seed) {
      int h = pos.getX() * -1640531527 ^ pos.getY() * -2048144789 ^ pos.getZ() * -1028477387 ^ (int)seed ^ 608135816;
      return mixToUnit(h);
   }

   private static float hash2D(int x, int z, long seed, int salt) {
      int h = x * -1640531527 ^ z * -2048144789 ^ (int)seed ^ salt;
      return mixToUnit(h);
   }

   private static float mixToUnit(int value) {
      int h = value ^ value >>> 16;
      h *= 2146121005;
      h ^= h >>> 15;
      h *= -2073254261;
      h ^= h >>> 16;
      return (h & 16777215) / 1.6777215E7F;
   }
}
