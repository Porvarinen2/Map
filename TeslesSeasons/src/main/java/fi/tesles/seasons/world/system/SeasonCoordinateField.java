package fi.tesles.seasons.world.system;

import net.minecraft.core.BlockPos;

/**
 * The deterministic coordinate field that turns a percentage target into a concrete set of
 * world coordinates.
 *
 * <p>This is what makes "25% snow" mean <em>the same 25% of the world</em> everywhere: the
 * physical block projector, the Voxy LOD mesh projector and the Voxy shader all threshold
 * the same pure function, so no seasonal history has to be stored anywhere to keep near
 * terrain and distant terrain agreeing.
 *
 * <h2>Invariants</h2>
 * <ul>
 *   <li><b>Pure.</b> Output depends only on world seed, block coordinates and a category
 *       salt. No {@code Random}, no time, no tick counter, no per-chunk state.</li>
 *   <li><b>Independently salted.</b> Snow coverage, snow depth, leaves, flowers, ground
 *       plants, mushrooms and berries each get their own salt, so a column that is snowy is
 *       not thereby also more likely to keep its flowers. Correlated salts produce visible
 *       stripes where two channels change together.</li>
 *   <li><b>Uniform.</b> Over a large area, {@code value < p} selects approximately a
 *       fraction {@code p} of columns. {@code SeasonFieldStatisticsTest} enforces this.</li>
 * </ul>
 *
 * <h2>Why the snow hash must not be "improved"</h2>
 * {@link #snowCoverage01} is mirrored bit-for-bit in GLSL by
 * {@code VoxyCanonicalVisualPostPatch}. Changing the mixing constants here without changing
 * that shader breaks near/far snow parity in a way that only shows up visually, kilometres
 * from the player. {@code VoxySnowParityTest} guards the Java side of this contract.
 *
 * <p>Dimension separation is carried by the per-world visual seed rather than an extra hash
 * term, which keeps the GLSL mirror a straight function of {@code (x, z, seed)}.
 */
public final class SeasonCoordinateField {
   // Fractional bits of sqrt(2), sqrt(3), sqrt(5)... - arbitrary but well-separated constants.
   public static final int SNOW_COVERAGE_SALT = 0x6A09E667;
   public static final int SNOW_DEPTH_SALT = 0xBB67AE85;
   public static final int LEAF_SALT = 0x3C6EF372;
   public static final int FLOWER_SALT = 0xA54FF53A;
   public static final int GROUND_PLANT_SALT = 0x510E527F;
   public static final int MUSHROOM_SALT = 0x9B05688C;
   public static final int BERRY_SALT = 0x1F83D9AB;

   /** Retained for source compatibility; flowers and ground plants now have distinct salts. */
   public static final int FLORA_SALT = FLOWER_SALT;

   private SeasonCoordinateField() {
   }

   /**
    * Canonical membership test. A coordinate belongs to the target set at retention
    * {@code p} exactly when its field value is below {@code p}.
    */
   public static boolean existsAtRetention(float fieldValue, float retention) {
      return fieldValue < retention;
   }

   public static float snowCoverage01(int x, int z, long seed) {
      return hash2D(x, z, seed, SNOW_COVERAGE_SALT);
   }

   public static float snowDepth01(int x, int z, long seed) {
      return hash2D(x, z, seed, SNOW_DEPTH_SALT);
   }

   public static float leaf01(BlockPos pos, long seed) {
      return leaf01(pos.getX(), pos.getY(), pos.getZ(), seed);
   }

   /** Allocation-free form, for scans that evaluate a whole section voxel by voxel. */
   public static float leaf01(int x, int y, int z, long seed) {
      return hash3D(x, y, z, seed, LEAF_SALT);
   }

   /** Legacy entry point: flowers. Prefer {@link #flora01(BlockPos, long, int)}. */
   public static float flora01(BlockPos pos, long seed) {
      return flora01(pos, seed, FLOWER_SALT);
   }

   /**
    * Flora membership for one category. Pass the salt matching the category so that
    * mushrooms, berries, flowers and ground plants select genuinely independent coordinates.
    */
   public static float flora01(BlockPos pos, long seed, int categorySalt) {
      return hash3D(pos.getX(), pos.getY(), pos.getZ(), seed, categorySalt);
   }

   private static float hash2D(int x, int z, long seed, int salt) {
      int h = x * 0x9E3779B9 ^ z * 0x85EBCA6B ^ (int) seed ^ salt;
      return mixToUnit(h);
   }

   private static float hash3D(int x, int y, int z, long seed, int salt) {
      int h = x * 0x9E3779B9 ^ y * 0x85EBCA6B ^ z * 0xC2B2AE35 ^ (int) seed ^ salt;
      return mixToUnit(h);
   }

   /**
    * Final avalanche to a uniform value in [0,1). Mirrored exactly by {@code teslesCellNoise}
    * in the Voxy shader patch - keep the two in lockstep.
    */
   private static float mixToUnit(int value) {
      int h = value ^ value >>> 16;
      h *= 0x7FEB352D;
      h ^= h >>> 15;
      h *= 0x846CA68B;
      h ^= h >>> 16;
      return (h & 0xFFFFFF) / 1.6777215E7F;
   }
}
