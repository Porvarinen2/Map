package fi.tesles.seasons.client.diagnostic;

import fi.tesles.seasons.client.ClientSeasonState;
import fi.tesles.seasons.client.voxy.VoxyShaderDiagnostics;
import fi.tesles.seasons.fix064.client.VoxySeasonRemeshScheduler;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.calendar.Season;
import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.Font;
import net.minecraft.client.gui.GuiGraphicsExtractor;

/**
 * A compact status panel down the right-hand edge, toggled with {@code /teslesseasons hud}.
 *
 * <p>Deliberately short. A panel long enough to cover every field would cover the game, so the
 * design rule here is that a line has to earn its place <em>in the season currently running</em>:
 * snow depth is worth a line in winter and worth nothing in July, and the leaf channel matters while
 * the canopy is moving and not once it has settled. The result is roughly a dozen lines that change
 * as the year does, rather than thirty that never do.
 *
 * <p>Everything shown is read-only and already computed elsewhere; the panel never asks the world a
 * question of its own.
 */
public final class SeasonHud {
   private static final int PAD = 4;
   private static final int LINE = 10;
   private static final int BG = 0xB4101318;
   private static final int HEAD = 0xFFFFD34A;
   private static final int LABEL = 0xFF8B93A1;
   private static final int VALUE = 0xFFE6EAF0;
   private static final int GOOD = 0xFF54C97A;
   private static final int WARN = 0xFFE2B23C;
   private static final int BAD = 0xFFE0574C;

   private static volatile boolean visible;

   private SeasonHud() {
   }

   public static boolean toggle() {
      visible = !visible;
      return visible;
   }

   public static boolean isVisible() {
      return visible;
   }

   public static void setVisible(boolean value) {
      visible = value;
   }

   /** One line of the panel: a label, a value, and the colour the value should read in. */
   private record Row(String label, String value, int colour) {
   }

   public static void render(GuiGraphicsExtractor gui, Minecraft client) {
      if (!visible || client.player == null) {
         return;
      }

      SeasonFrame frame = ClientSeasonState.frame();
      List<Row> rows = build(frame, client);
      Font font = client.font;

      int width = 0;
      for (Row row : rows) {
         width = Math.max(width, font.width(row.label()) + font.width(row.value()) + 14);
      }
      width = Math.max(width, font.width("TESLESSEASONS") + 14);

      int right = gui.guiWidth() - PAD;
      int left = right - width - PAD * 2;
      int top = PAD + 12;
      int height = PAD * 2 + LINE * (rows.size() + 1) + 2;

      gui.fill(left, top, right, top + height, BG);
      gui.fill(left, top, left + 1, top + height, 0xFF2F3A48);

      int y = top + PAD;
      gui.text(font, title(frame), left + PAD, y, HEAD);
      y += LINE + 2;

      for (Row row : rows) {
         gui.text(font, row.label(), left + PAD, y, LABEL);
         int vx = right - PAD - font.width(row.value());
         gui.text(font, row.value(), vx, y, row.colour());
         y += LINE;
      }
   }

   private static String title(SeasonFrame frame) {
      return frame.season() + " / " + frame.phase() + "  " + pct(frame.progress());
   }

   /**
    * Chooses the lines worth showing for this frame.
    *
    * <p>The order is fixed - where a value sits should not move as the year turns - but a line is
    * omitted entirely when its channel has nothing to say.
    */
   private static List<Row> build(SeasonFrame frame, Minecraft client) {
      List<Row> rows = new ArrayList<>(16);

      // --- what the world is being asked for, filtered to what is actually moving
      if (frame.autumnColor() > 0.0F) {
         rows.add(new Row("autumn", pct(frame.autumnColor()), VALUE));
      }
      if (frame.leafRetention() < 0.9999F) {
         rows.add(new Row("leaves", pct(frame.leafRetention()), VALUE));
      }
      if (frame.snowCoverage() > 0.0F) {
         rows.add(new Row("snow", pct(frame.snowCoverage()) + " · " + layers(frame) + "/8",
            frame.snowThawing() ? WARN : VALUE));
      }
      if (frame.flowerRetention() < 0.9999F || frame.plantRetention() < 0.9999F) {
         rows.add(new Row("flora f/p", pct(frame.flowerRetention()) + " " + pct(frame.plantRetention()), VALUE));
      }
      if (frame.mushroomRetention() > 0.0F) {
         rows.add(new Row("mushrooms", pct(frame.mushroomRetention()), VALUE));
      }
      if (frame.berryRetention() > 0.0F && frame.berryRetention() < 0.9999F) {
         rows.add(new Row("berries", pct(frame.berryRetention()), VALUE));
      }
      if (frame.groundFrost() > 0.0F) {
         rows.add(new Row("frost", pct(frame.groundFrost()), VALUE));
      }
      if (frame.springFreshness() > 0.0F) {
         rows.add(new Row("freshness", pct(frame.springFreshness()), VALUE));
      }
      if (frame.season() == Season.SUMMER && frame.leafRetention() >= 0.9999F && frame.snowCoverage() <= 0.0F) {
         // Summer asks for nothing; say so rather than showing an empty panel.
         rows.add(new Row("world", "neutral", GOOD));
      }

      rows.add(new Row("revision", Long.toString(frame.revision()), LABEL));

      // --- whether the distance agrees with the ground
      int[] counts = sectionCounts(frame);
      if (counts[0] > 0) {
         int stale = counts[0] - counts[1];
         float staleFraction = stale / (float) counts[0];
         rows.add(new Row("voxy lod", counts[1] + "/" + counts[0],
            staleFraction <= 0.05F ? GOOD : (staleFraction <= 0.25F ? WARN : BAD)));
         if (stale > 0) {
            rows.add(new Row("  stale", Integer.toString(stale), staleFraction <= 0.25F ? WARN : BAD));
         }
      }

      long bindAge = VoxyShaderDiagnostics.lastSeasonBindAgeMillis();
      if (bindAge >= 0L) {
         rows.add(new Row("shader", bindAge < 2000L ? "bound" : "stale " + bindAge / 1000L + "s",
            bindAge < 2000L ? GOOD : BAD));
      } else if (VoxyShaderDiagnostics.isBridgeApplied()) {
         rows.add(new Row("shader", "no bind", BAD));
      }

      // --- cost, only when it is worth a glance
      Runtime runtime = Runtime.getRuntime();
      long usedMib = (runtime.totalMemory() - runtime.freeMemory()) / 1048576L;
      long maxMib = Math.max(1L, runtime.maxMemory() / 1048576L);
      int heapPercent = (int) (usedMib * 100L / maxMib);
      if (heapPercent >= 70) {
         rows.add(new Row("heap", usedMib + "M " + heapPercent + "%", heapPercent >= 88 ? BAD : WARN));
      }

      if (PerformanceLog.isRunning()) {
         rows.add(new Row("capture", "recording", HEAD));
      }

      return rows;
   }

   private static int[] sectionCounts(SeasonFrame frame) {
      try {
         return VoxySeasonRemeshScheduler.sectionCounts(frame.geometryKey());
      } catch (Throwable ignored) {
         return new int[]{0, 0};
      }
   }

   private static int layers(SeasonFrame frame) {
      return Math.round(frame.snowDepthTarget() * 8.0F);
   }

   private static String pct(float value) {
      return Math.round(value * 100.0F) + "%";
   }
}
