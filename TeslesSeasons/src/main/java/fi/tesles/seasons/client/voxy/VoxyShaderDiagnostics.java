package fi.tesles.seasons.client.voxy;

/**
 * What the Voxy shader bridge actually achieved this session, for the diagnostic bundle.
 *
 * <p>The uniform counters are deliberately aggregates rather than "the last shader we saw".
 * Voxy binds many programs - compute passes, the section renderer, Iris variants - and only the
 * LOD terrain program carries TESLES uniforms. A single last-writer-wins counter therefore read
 * {@code uniforms=0} whenever any other program happened to resolve last, which is the common
 * case; a capture taken from a correctly working game was indistinguishable from one where the
 * bridge had failed outright. {@link #maxResolvedUniforms} answers the question that matters -
 * did any program resolve the full uniform block - and {@link #seasonPrograms} says how many did.
 */
public final class VoxyShaderDiagnostics {
   /** Uniforms the binder looks up on each program. Kept in sync with VoxyShaderUniformMixin. */
   public static final int EXPECTED_UNIFORMS = 12;

   private static volatile boolean vertexPatched;
   private static volatile boolean fragmentPatched;
   private static volatile int maxResolvedUniforms;
   private static volatile int programsInspected;
   private static volatile int seasonPrograms;
   private static volatile long lastUniformBindMillis;
   private static volatile long lastSeasonUniformBindMillis;

   private VoxyShaderDiagnostics() {
   }

   public static void markVertexPatched() {
      vertexPatched = true;
   }

   public static void markFragmentPatched() {
      fragmentPatched = true;
   }

   /** Called once per shader program, the first time it binds. */
   public static synchronized void markUniformsResolved(int count) {
      int resolved = Math.max(0, count);
      programsInspected++;
      if (resolved > maxResolvedUniforms) {
         maxResolvedUniforms = resolved;
      }

      if (resolved > 0) {
         seasonPrograms++;
      }

      lastUniformBindMillis = System.currentTimeMillis();
   }

   /** Called on every bind; {@code seasonProgram} distinguishes the LOD terrain program. */
   public static void markUniformBind(boolean seasonProgram) {
      long now = System.currentTimeMillis();
      lastUniformBindMillis = now;
      if (seasonProgram) {
         lastSeasonUniformBindMillis = now;
      }
   }

   public static String summary() {
      long age = age(lastUniformBindMillis);
      long seasonAge = age(lastSeasonUniformBindMillis);
      String health;
      if (!vertexPatched || !fragmentPatched) {
         health = "BRIDGE-NOT-APPLIED";
      } else if (seasonPrograms == 0) {
         health = "NO-PROGRAM-CARRIES-UNIFORMS";
      } else if (maxResolvedUniforms < EXPECTED_UNIFORMS) {
         health = "PARTIAL(" + maxResolvedUniforms + "/" + EXPECTED_UNIFORMS + ")";
      } else {
         health = "OK";
      }

      return "voxyShader: vertexPatched=" + vertexPatched
         + " fragmentPatched=" + fragmentPatched
         + " status=" + health
         + " uniformsMax=" + maxResolvedUniforms + "/" + EXPECTED_UNIFORMS
         + " seasonPrograms=" + seasonPrograms + "/" + programsInspected
         + " lastBindAgeMs=" + age
         + " lastSeasonBindAgeMs=" + seasonAge;
   }

   private static long age(long stamp) {
      return stamp <= 0L ? -1L : Math.max(0L, System.currentTimeMillis() - stamp);
   }
}
