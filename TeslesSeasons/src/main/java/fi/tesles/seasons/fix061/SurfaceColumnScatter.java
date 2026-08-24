package fi.tesles.seasons.fix061;

public final class SurfaceColumnScatter {
   private SurfaceColumnScatter() {
   }

   public static int permute(int columnIndex) {
      int value = columnIndex & 0xFF;
      int left = value >>> 4 & 15;
      int right = value & 15;
      int[] round = new int[]{3, 11, 5, 13};

      for (int c : round) {
         int f = (right * 5 + c ^ right << 1 ^ right >>> 1) & 15;
         int nextLeft = right;
         right = (left ^ f) & 15;
         left = nextLeft;
      }

      return left << 4 | right;
   }
}
