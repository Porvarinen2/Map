package fi.tesles.seasons.client.diagnostic;

import com.mojang.blaze3d.platform.NativeImage;
import fi.tesles.seasons.client.ClientSeasonState;
import fi.tesles.seasons.client.render.SeasonalClassifier;
import fi.tesles.seasons.fix064.client.VoxySeasonRemeshScheduler;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.world.system.SnowSystem;
import java.nio.file.Path;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.levelgen.Heightmap.Types;

/**
 * Top-down maps of the diagnostic state, rendered from data rather than from the camera.
 *
 * <p>A screenshot shows one direction from one place. What a seasonal fault actually needs is a
 * plan view of a wide area with the mod's own state drawn on it, because the faults that matter are
 * regional: a band of the wrong season at one distance, snow that stops at a chunk line, a patch
 * that never thaws. Those are invisible from the ground and obvious from above.
 *
 * <p>Two images are produced per capture.
 *
 * <ul>
 *   <li><b>terrain</b> — what the world <em>is</em>, from the client's real block data: surface
 *       category, snow depth and a height relief.</li>
 *   <li><b>voxy</b> — what Voxy <em>holds</em>: every watched LOD section, coloured by whether its
 *       geometry was built against the frame in force. Red is a section still showing an older
 *       season, which is the failure this mod exists to prevent.</li>
 * </ul>
 *
 * <p>Neither image moves the player, changes the camera or touches the world.
 */
public final class AerialMapRenderer {
   /** Half-width of the mapped area, in blocks. 512 covers well past the vanilla render distance. */
   public static final int DEFAULT_RADIUS_BLOCKS = 512;

   /** World blocks per pixel. 2 keeps a 1024-block map to a 512-pixel image. */
   private static final int BLOCKS_PER_PIXEL = 2;

   private static final int LEGEND_HEIGHT = 74;

   private AerialMapRenderer() {
   }

   /**
    * Renders both maps.
    *
    * @return the number of images successfully written
    */
   public static int render(Minecraft client, Path terrainPng, Path voxyPng, int radiusBlocks) {
      ClientLevel level = client.level;
      if (level == null || client.player == null) {
         return 0;
      }

      int centreX = (int) Math.floor(client.player.getX());
      int centreZ = (int) Math.floor(client.player.getZ());
      SeasonFrame frame = ClientSeasonState.frame();
      int written = 0;

      Sample sample = sampleTerrain(level, centreX, centreZ, radiusBlocks);
      if (writeTerrain(sample, terrainPng, frame, centreX, centreZ, radiusBlocks)) {
         written++;
      }
      if (writeVoxy(sample, voxyPng, frame, centreX, centreZ, radiusBlocks)) {
         written++;
      }
      return written;
   }

   // ---------------------------------------------------------------- sampling

   /** One pass over the area, so both images are drawn from the same instant. */
   private record Sample(int size, int[] colour, int[] height, boolean[] known, int minHeight, int maxHeight,
                         int columnsKnown, int columnsSnowy) {
   }

   private static Sample sampleTerrain(ClientLevel level, int centreX, int centreZ, int radiusBlocks) {
      int size = radiusBlocks * 2 / BLOCKS_PER_PIXEL;
      int[] colour = new int[size * size];
      int[] height = new int[size * size];
      boolean[] known = new boolean[size * size];
      int minHeight = Integer.MAX_VALUE;
      int maxHeight = Integer.MIN_VALUE;
      int columnsKnown = 0;
      int columnsSnowy = 0;
      BlockPos.MutableBlockPos cursor = new BlockPos.MutableBlockPos();

      for (int py = 0; py < size; py++) {
         int wz = centreZ - radiusBlocks + py * BLOCKS_PER_PIXEL;
         for (int px = 0; px < size; px++) {
            int wx = centreX - radiusBlocks + px * BLOCKS_PER_PIXEL;
            int index = py * size + px;

            // Outside the client's loaded chunks there is no block data at all. Those pixels are
            // left unknown rather than guessed, so the terrain map never invents ground - and the
            // boundary it leaves is itself informative: it is the edge of what the client knows.
            if (!level.hasChunkAt(wx, wz)) {
               continue;
            }

            // WORLD_SURFACE, not MOTION_BLOCKING_NO_LEAVES. The latter is what the snow pass uses
            // to find the ground a layer should rest on, and a one-layer snow does not block motion
            // - so it reports the grass block underneath and the map drew a green world in deep
            // winter. A map wants whatever is visible from above: canopy, snow, grass.
            int top = level.getHeight(Types.WORLD_SURFACE, wx, wz) - 1;
            if (top < level.getMinY()) {
               continue;
            }

            cursor.set(wx, top, wz);
            BlockState state = level.getBlockState(cursor);
            int base = AerialMapPalette.forCategory(SeasonalClassifier.categoryFor(state).voxyId());

            if (!state.getFluidState().isEmpty()) {
               base = AerialMapPalette.WATER;
            }

            int layers = SnowSystem.layers(state);
            if (layers > 0) {
               columnsSnowy++;
               // Deeper snow reads brighter, so accumulation is visible as shading rather than
               // needing a second image.
               base = AerialMapPalette.mix(AerialMapPalette.SNOW, 0xFFFFFF, (layers - 1) / 14.0F);
            }

            colour[index] = base;
            height[index] = top;
            known[index] = true;
            columnsKnown++;
            minHeight = Math.min(minHeight, top);
            maxHeight = Math.max(maxHeight, top);
         }
      }

      return new Sample(size, colour, height, known,
         minHeight == Integer.MAX_VALUE ? 0 : minHeight,
         maxHeight == Integer.MIN_VALUE ? 1 : maxHeight,
         columnsKnown, columnsSnowy);
   }

   // ---------------------------------------------------------------- terrain map

   private static boolean writeTerrain(Sample sample, Path out, SeasonFrame frame,
                                       int centreX, int centreZ, int radiusBlocks) {
      Canvas canvas = new Canvas(sample.size(), sample.size() + LEGEND_HEIGHT, sample.size());

      for (int py = 0; py < sample.size(); py++) {
         for (int px = 0; px < sample.size(); px++) {
            int index = py * sample.size() + px;
            if (sample.known()[index]) {
               canvas.set(px, py, AerialMapPalette.shade(sample.colour()[index], sample.height()[index],
                  sample.minHeight(), sample.maxHeight()));
            }
         }
      }

      drawGrid(canvas, sample.size(), centreX, centreZ, radiusBlocks);
      drawPlayer(canvas, sample.size());
      drawScaleBar(canvas, sample.size());
      drawLegendStrip(canvas, sample.size(), new int[]{
         AerialMapPalette.GRASS, AerialMapPalette.LEAF, AerialMapPalette.EVERGREEN,
         AerialMapPalette.SNOW, AerialMapPalette.WATER, AerialMapPalette.FLOWER,
         AerialMapPalette.MUSHROOM, AerialMapPalette.GROUND, AerialMapPalette.BUILT
      });
      return canvas.write(out);
   }

   // ---------------------------------------------------------------- voxy map

   private static boolean writeVoxy(Sample sample, Path out, SeasonFrame frame,
                                    int centreX, int centreZ, int radiusBlocks) {
      Canvas canvas = new Canvas(sample.size(), sample.size() + LEGEND_HEIGHT, sample.size());

      // The terrain underneath, heavily dimmed, so the LOD overlay can be located against
      // recognisable landscape rather than floating in the dark.
      for (int py = 0; py < sample.size(); py++) {
         for (int px = 0; px < sample.size(); px++) {
            int index = py * sample.size() + px;
            if (sample.known()[index]) {
               canvas.set(px, py, AerialMapPalette.mix(sample.colour()[index], AerialMapPalette.VOID, 0.72F));
            }
         }
      }

      {
         List<VoxySeasonRemeshScheduler.SectionState> sections =
            VoxySeasonRemeshScheduler.snapshotSections(frame.geometryKey());

         // Coarse levels first, so a fine section drawn over them stays visible.
         sections.sort((a, b) -> Integer.compare(b.level(), a.level()));

         for (VoxySeasonRemeshScheduler.SectionState section : sections) {
            int span = section.spanBlocks();
            int x0 = toPixel(section.minBlockX(), centreX, radiusBlocks);
            int z0 = toPixel(section.minBlockZ(), centreZ, radiusBlocks);
            int x1 = toPixel(section.minBlockX() + span, centreX, radiusBlocks);
            int z1 = toPixel(section.minBlockZ() + span, centreZ, radiusBlocks);

            int tint = section.protectedByHandoff()
               ? AerialMapPalette.VOXY_HANDOFF
               : (section.current() ? AerialMapPalette.VOXY_CURRENT : AerialMapPalette.VOXY_STALE);

            // A coarse section covers a lot of ground, so it is drawn fainter; otherwise one level-4
            // section would bury everything finer underneath it.
            float strength = section.current() ? 0.34F : 0.60F;
            strength = Math.max(0.16F, strength - section.level() * 0.05F);
            canvas.blendRect(x0, z0, x1, z1, tint, strength);
            canvas.outlineRect(x0, z0, x1, z1, tint);
         }
      }

      drawHandoffRing(canvas, sample.size(), radiusBlocks);
      drawPlayer(canvas, sample.size());
      drawScaleBar(canvas, sample.size());
      drawLegendStrip(canvas, sample.size(), new int[]{
         AerialMapPalette.VOXY_CURRENT, AerialMapPalette.VOXY_STALE, AerialMapPalette.VOXY_HANDOFF
      });
      return canvas.write(out);
   }

   // ---------------------------------------------------------------- drawing helpers

   /**
    * An RGB pixel buffer with the few primitives the maps need.
    *
    * <p>Drawing happens here rather than straight into a {@link NativeImage} because several passes
    * blend over what is already there, and NativeImage does not expose a pixel read. The buffer is
    * converted once, at the end.
    */
   private static final class Canvas {
      private final int width;
      private final int height;
      /** Rows below this are the legend strip; map primitives must not draw into it. */
      private final int mapHeight;
      private final int[] pixels;

      private Canvas(int width, int height, int mapHeight) {
         this.width = width;
         this.height = height;
         this.mapHeight = mapHeight;
         this.pixels = new int[width * height];
         java.util.Arrays.fill(this.pixels, AerialMapPalette.VOID);
      }

      private boolean inMap(int x, int y) {
         return x >= 0 && x < this.width && y >= 0 && y < this.mapHeight;
      }

      void set(int x, int y, int rgb) {
         if (this.inMap(x, y)) {
            this.pixels[y * this.width + x] = rgb;
         }
      }

      void fill(int x0, int y0, int x1, int y1, int rgb) {
         for (int y = Math.max(0, y0); y < Math.min(this.height, y1); y++) {
            for (int x = Math.max(0, x0); x < Math.min(this.width, x1); x++) {
               this.pixels[y * this.width + x] = rgb;
            }
         }
      }

      void blendRect(int x0, int y0, int x1, int y1, int rgb, float amount) {
         for (int y = Math.max(0, y0); y < Math.min(this.mapHeight, y1); y++) {
            for (int x = Math.max(0, x0); x < Math.min(this.width, x1); x++) {
               int index = y * this.width + x;
               this.pixels[index] = AerialMapPalette.mix(this.pixels[index], rgb, amount);
            }
         }
      }

      void outlineRect(int x0, int y0, int x1, int y1, int rgb) {
         for (int x = Math.max(0, x0); x < Math.min(this.width, x1); x++) {
            this.set(x, y0, rgb);
            this.set(x, y1 - 1, rgb);
         }
         for (int y = Math.max(0, y0); y < Math.min(this.mapHeight, y1); y++) {
            this.set(x0, y, rgb);
            this.set(x1 - 1, y, rgb);
         }
      }

      boolean write(Path out) {
         try (NativeImage image = new NativeImage(NativeImage.Format.RGBA, this.width, this.height, false)) {
            for (int y = 0; y < this.height; y++) {
               for (int x = 0; x < this.width; x++) {
                  image.setPixelABGR(x, y, AerialMapPalette.toAbgr(this.pixels[y * this.width + x]));
               }
            }
            image.writeToFile(out);
            return true;
         } catch (Throwable ignored) {
            return false;
         }
      }
   }

   private static int toPixel(int world, int centre, int radiusBlocks) {
      return (world - (centre - radiusBlocks)) / BLOCKS_PER_PIXEL;
   }

   /** Chunk lines every 16 blocks, region lines every 512, so distances are countable. */
   private static void drawGrid(Canvas canvas, int size, int centreX, int centreZ, int radiusBlocks) {
      int originX = centreX - radiusBlocks;
      int originZ = centreZ - radiusBlocks;
      for (int px = 0; px < size; px++) {
         int wx = originX + px * BLOCKS_PER_PIXEL;
         int colour = gridColour(wx);
         if (colour >= 0) {
            canvas.blendRect(px, 0, px + 1, size, colour, 0.5F);
         }
      }
      for (int py = 0; py < size; py++) {
         int wz = originZ + py * BLOCKS_PER_PIXEL;
         int colour = gridColour(wz);
         if (colour >= 0) {
            canvas.blendRect(0, py, size, py + 1, colour, 0.5F);
         }
      }
   }

   private static int gridColour(int world) {
      if (Math.floorMod(world, 512) < BLOCKS_PER_PIXEL) {
         return AerialMapPalette.GRID_REGION;
      }
      return Math.floorMod(world, 16) < BLOCKS_PER_PIXEL ? AerialMapPalette.GRID_CHUNK : -1;
   }

   /** The radius inside which Voxy defers to real chunks - the seam players notice. */
   private static void drawHandoffRing(Canvas canvas, int size, int radiusBlocks) {
      int centre = size / 2;
      int r = VoxySeasonRemeshScheduler.handoffRadius() / BLOCKS_PER_PIXEL;
      if (r <= 0 || r > size) {
         return;
      }
      for (int a = 0; a < 1440; a++) {
         double angle = a * Math.PI / 720.0;
         canvas.set(centre + (int) Math.round(Math.cos(angle) * r),
                    centre + (int) Math.round(Math.sin(angle) * r), AerialMapPalette.PLAYER);
      }
   }

   private static void drawPlayer(Canvas canvas, int size) {
      int c = size / 2;
      for (int d = -4; d <= 4; d++) {
         canvas.set(c + d, c, AerialMapPalette.PLAYER);
         canvas.set(c, c + d, AerialMapPalette.PLAYER);
      }
   }

   /** A 256-block bar, so distances can be measured off the image. */
   private static void drawScaleBar(Canvas canvas, int size) {
      int length = 256 / BLOCKS_PER_PIXEL;
      int x0 = 12;
      int y0 = size - 16;
      canvas.fill(x0, y0, x0 + length, y0 + 3, AerialMapPalette.PANEL_FG);
      canvas.fill(x0, y0 - 3, x0 + 2, y0 + 6, AerialMapPalette.PANEL_FG);
      canvas.fill(x0 + length - 2, y0 - 3, x0 + length, y0 + 6, AerialMapPalette.PANEL_FG);
   }

   /**
    * Colour swatches below the map.
    *
    * <p>NativeImage cannot draw text, so the legend is swatches in a documented order and the words
    * live in the capture's state file. That keeps the image dependency-free.
    */
   private static void drawLegendStrip(Canvas canvas, int size, int[] colours) {
      canvas.fill(0, size, canvas.width, canvas.height, AerialMapPalette.PANEL_BG);
      int x = 12;
      for (int colour : colours) {
         canvas.fill(x, size + 12, x + 34, size + 34, colour);
         x += 42;
      }
   }
}
