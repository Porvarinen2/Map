package fi.tesles.seasons.client.voxy;

public final class VoxyShaderDiagnostics {
   private static volatile boolean vertexPatched;
   private static volatile boolean fragmentPatched;
   private static volatile int resolvedUniforms;
   private static volatile long lastUniformBindMillis;

   private VoxyShaderDiagnostics() {
   }

   public static void markVertexPatched() {
      vertexPatched = true;
   }

   public static void markFragmentPatched() {
      fragmentPatched = true;
   }

   public static void markUniformsResolved(int count) {
      resolvedUniforms = Math.max(0, count);
      lastUniformBindMillis = System.currentTimeMillis();
   }

   public static void markUniformBind() {
      lastUniformBindMillis = System.currentTimeMillis();
   }

   public static String summary() {
      long age = lastUniformBindMillis <= 0L ? -1L : Math.max(0L, System.currentTimeMillis() - lastUniformBindMillis);
      return "voxyShader: vertexPatched=" + vertexPatched + " fragmentPatched=" + fragmentPatched + " uniforms=" + resolvedUniforms + " lastBindAgeMs=" + age;
   }
}
