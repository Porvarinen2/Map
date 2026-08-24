package fi.tesles.seasons.fix061;

public final class OrganicSnowField {
   private OrganicSnowField() {
   }

   public static double coverageNoise(int blockX, int blockZ, long visualSeed) {
      int seed = (int)visualSeed;
      float x = blockX;
      float z = blockZ;
      float warpX = (valueNoise(x, z, 73.0F, seed, 1779033703) - 0.5F) * 28.0F + (valueNoise(x, z, 31.0F, seed, 1359893119) - 0.5F) * 10.0F;
      float warpZ = (valueNoise(x, z, 79.0F, seed, -1150833019) - 0.5F) * 28.0F + (valueNoise(x, z, 29.0F, seed, -1694144372) - 0.5F) * 10.0F;
      float wx = x + warpX;
      float wz = z + warpZ;
      float broad = valueNoise(wx, wz, 59.0F, seed, 1013904242);
      float medium = valueNoise(wx, wz, 23.0F, seed, -1521486534);
      float fine = valueNoise(wx, wz, 11.0F, seed, 528734635);
      float micro = valueNoise(x, z, 5.0F, seed, 1541459225);
      float jitter = cellNoise(blockX, blockZ, seed, -1028477387);
      float raw = broad * 0.5F + medium * 0.25F + fine * 0.14F + micro * 0.05F + jitter * 0.06F;
      float redistributed = (float)(1.0 / (1.0 + Math.exp(-(raw - 0.5F) * 12.0F)));
      return clamp01(redistributed);
   }

   public static boolean wantsSnow(double snowCover, double noise) {
      if (snowCover <= 0.005) {
         return false;
      } else {
         return snowCover >= 0.995 ? true : noise <= clamp01(snowCover);
      }
   }

   private static float valueNoise(float x, float z, float scale, int seed, int salt) {
      float qx = x / scale;
      float qz = z / scale;
      int cx = floorToInt(qx);
      int cz = floorToInt(qz);
      float fx = qx - cx;
      float fz = qz - cz;
      fx = fx * fx * (3.0F - 2.0F * fx);
      fz = fz * fz * (3.0F - 2.0F * fz);
      float n00 = cellNoise(cx, cz, seed, salt);
      float n10 = cellNoise(cx + 1, cz, seed, salt);
      float n01 = cellNoise(cx, cz + 1, seed, salt);
      float n11 = cellNoise(cx + 1, cz + 1, seed, salt);
      float nx0 = mix(n00, n10, fx);
      float nx1 = mix(n01, n11, fx);
      return mix(nx0, nx1, fz);
   }

   private static float cellNoise(int cellX, int cellZ, int seed, int salt) {
      int h = cellX * -1640531527 ^ cellZ * -2048144789 ^ seed ^ salt;
      h ^= h >>> 16;
      h *= 2146121005;
      h ^= h >>> 15;
      h *= -2073254261;
      h ^= h >>> 16;
      return (h & 16777215) / 1.6777215E7F;
   }

   private static int floorToInt(float value) {
      int i = (int)value;
      return value < i ? i - 1 : i;
   }

   private static float mix(float a, float b, float t) {
      return a + (b - a) * t;
   }

   private static double clamp01(double value) {
      return Math.max(0.0, Math.min(1.0, value));
   }
}
