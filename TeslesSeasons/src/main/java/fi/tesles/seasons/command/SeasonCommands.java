package fi.tesles.seasons.command;

import com.mojang.brigadier.arguments.IntegerArgumentType;
import com.mojang.brigadier.arguments.StringArgumentType;
import com.mojang.brigadier.builder.LiteralArgumentBuilder;
import com.mojang.brigadier.context.CommandContext;
import com.mojang.brigadier.exceptions.CommandSyntaxException;
import fi.tesles.seasons.SeasonEngine;
import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.compat.VoxyServerBackfillBridge;
import fi.tesles.seasons.debug.SeasonDebugController;
import fi.tesles.seasons.ServerDiagnosticSampler;
import fi.tesles.seasons.network.DiagnosticCapturePayload;
import fi.tesles.seasons.weather.SeasonWeatherController;
import fi.tesles.seasons.weather.TeslesWeatherType;
import fi.tesles.seasons.world.SeasonalWorldReconciler;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.Locale;
import net.fabricmc.fabric.api.command.v2.CommandRegistrationCallback;
import net.fabricmc.fabric.api.networking.v1.ServerPlayNetworking;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.permissions.Permissions;

public final class SeasonCommands {
   private SeasonCommands() {
   }

   public static void register() {
      CommandRegistrationCallback.EVENT
         .register(
            (CommandRegistrationCallback)(dispatcher, registryAccess, environment) -> dispatcher.register(
               (LiteralArgumentBuilder)((LiteralArgumentBuilder)((LiteralArgumentBuilder)((LiteralArgumentBuilder)((LiteralArgumentBuilder)((LiteralArgumentBuilder)((LiteralArgumentBuilder)((LiteralArgumentBuilder)((LiteralArgumentBuilder)Commands.literal(
                                             "teslesseasons"
                                          )
                                          .requires(source -> source.permissions().hasPermission(Permissions.COMMANDS_MODERATOR)))
                                       .executes(SeasonCommands::status))
                                    .then(Commands.literal("status").executes(SeasonCommands::status)))
                                 .then(
                                    ((LiteralArgumentBuilder)Commands.literal("hud").executes(context -> hud(context, "toggle")))
                                       .then(Commands.literal("on").executes(context -> hud(context, "on")))
                                       .then(Commands.literal("off").executes(context -> hud(context, "off"))))
                                 .then(Commands.literal("reconcile").executes(SeasonCommands::reconcile)))
                              .then(
                                 ((LiteralArgumentBuilder)Commands.literal("voxy").then(Commands.literal("status").executes(SeasonCommands::voxyStatus)))
                                    .then(Commands.literal("backfill").executes(SeasonCommands::voxyBackfill))
                              ))
                           .then(
                              ((LiteralArgumentBuilder)Commands.literal("diagnostic")
                                    .then(Commands.literal("capture").executes(SeasonCommands::diagnosticCapture)))
                                 .then(
                                    ((LiteralArgumentBuilder)Commands.literal("year").executes(context -> diagnosticYear(context, 600)))
                                       .then(Commands.argument("seconds", IntegerArgumentType.integer(60, 86400)).executes(SeasonCommands::diagnosticYear))
                                 )
                           ))
                        .then(Commands.literal("weather").then(Commands.argument("type", StringArgumentType.word()).executes(SeasonCommands::weather))))
                     .then(
                        ((LiteralArgumentBuilder)Commands.literal("timelapse")
                              .then(Commands.argument("seconds", IntegerArgumentType.integer(20, 86400)).executes(SeasonCommands::timelapse)))
                           .then(Commands.literal("stop").executes(SeasonCommands::clear))
                     ))
                  .then(
                     ((LiteralArgumentBuilder)((LiteralArgumentBuilder)((LiteralArgumentBuilder)((LiteralArgumentBuilder)((LiteralArgumentBuilder)((LiteralArgumentBuilder)Commands.literal(
                                             "debug"
                                          )
                                          .executes(SeasonCommands::debugHelp))
                                       .then(Commands.literal("clear").executes(SeasonCommands::clear)))
                                    .then(
                                       Commands.literal("season")
                                          .then(Commands.argument("season", StringArgumentType.word()).executes(SeasonCommands::forceSeason))
                                    ))
                                 .then(Commands.literal("date").then(Commands.argument("date", StringArgumentType.word()).executes(SeasonCommands::forceDate))))
                              .then(
                                 Commands.literal("phase")
                                    .then(
                                       Commands.argument("season", StringArgumentType.word())
                                          .then(
                                             Commands.argument("phase", StringArgumentType.word())
                                                .then(Commands.argument("percent", IntegerArgumentType.integer(0, 100)).executes(SeasonCommands::forcePhase))
                                          )
                                    )
                              ))
                           .then(
                              Commands.literal("transition")
                                 .then(
                                    Commands.argument("from", StringArgumentType.word())
                                       .then(
                                          Commands.argument("to", StringArgumentType.word())
                                             .then(Commands.argument("seconds", IntegerArgumentType.integer(5, 3600)).executes(SeasonCommands::transition))
                                       )
                                 )
                           ))
                        .then(
                           Commands.literal("timelapse")
                              .then(Commands.argument("seconds", IntegerArgumentType.integer(20, 86400)).executes(SeasonCommands::timelapse))
                        )
                  )
            )
         );
   }

   private static int status(CommandContext<CommandSourceStack> context) {
      long now = System.currentTimeMillis();
      SeasonSnapshot snapshot = SeasonEngine.current();
      ((CommandSourceStack)context.getSource())
         .sendSuccess(
            () -> Component.literal(
               "TeslesSeasons: "
                  + snapshot.season().name()
                  + " / "
                  + snapshot.phase().name()
                  + " "
                  + Math.round(snapshot.phaseProgress() * 100.0F)
                  + "% | date="
                  + snapshot.year()
                  + "-"
                  + two(snapshot.month())
                  + "-"
                  + two(snapshot.dayOfMonth())
                  + " | debug="
                  + SeasonDebugController.description(now, TeslesSeasons.CONFIG)
            ),
            false
         );
      ((CommandSourceStack)context.getSource())
         .sendSuccess(
            () -> Component.literal(
               "visual: autumn="
                  + pct(snapshot.autumnColor())
                  + " leaves="
                  + pct(snapshot.leafRetention())
                  + " flowers="
                  + pct(snapshot.flowerRetention())
                  + " mushrooms="
                  + pct(snapshot.mushroomRetention())
                  + " dormancy="
                  + pct(snapshot.groundDormancy())
                  + " snow="
                  + pct(snapshot.snowCover())
                  + " spring="
                  + pct(snapshot.springFreshness())
            ),
            false
         );
      ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal(SeasonalWorldReconciler.status()), false);
      ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal(VoxyServerBackfillBridge.status()), false);
      ((CommandSourceStack)context.getSource())
         .sendSuccess(
            () -> Component.literal(
               "weather: " + SeasonWeatherController.currentWeather().id() + (SeasonWeatherController.forcedWeather() == null ? " (auto)" : " (forced)")
            ),
            false
         );
      return 1;
   }

   private static int debugHelp(CommandContext<CommandSourceStack> context) {
      ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal("Debug: /teslesseasons timelapse <seconds>  (full looping year)"), false);
      ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal("       /teslesseasons timelapse stop"), false);
      ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal("       /teslesseasons debug season <spring|summer|autumn|winter>"), false);
      ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal("       /teslesseasons debug date <YYYY-MM-DD>"), false);
      ((CommandSourceStack)context.getSource())
         .sendSuccess(() -> Component.literal("       /teslesseasons debug phase <season> <incoming|stable|outgoing> <0-100>"), false);
      ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal("       /teslesseasons debug transition <from> <to> <seconds>"), false);
      ((CommandSourceStack)context.getSource())
         .sendSuccess(() -> Component.literal("       /teslesseasons reconcile | /teslesseasons voxy <status|backfill> | /teslesseasons debug clear"), false);
      ((CommandSourceStack)context.getSource())
         .sendSuccess(
            () -> Component.literal(
               "       /teslesseasons weather <auto|clear|cloudy|drizzle|rain|heavy_rain|thunderstorm|light_snow|snow|heavy_snow|blizzard>"
            ),
            false
         );
      ((CommandSourceStack)context.getSource())
         .sendSuccess(() -> Component.literal("       /teslesseasons diagnostic capture | /teslesseasons diagnostic year [seconds] (default 600)"), false);
      return 1;
   }

   private static int diagnosticCapture(CommandContext<CommandSourceStack> context) {
      ServerPlayer player = commandPlayer(context);
      if (player == null) {
         return 0;
      } else {
         ServerDiagnosticSampler.begin(player, 20);
         ServerPlayNetworking.send(player, DiagnosticCapturePayload.single(diagnosticServerSummary()));
         ((CommandSourceStack)context.getSource())
            .sendSuccess(() -> Component.literal("Requested client screenshot + season/Voxy/world-sample diagnostic ZIP."), false);
         return 1;
      }
   }

   /**
    * Toggles the client's status panel.
    *
    * <p>The panel is drawn client-side but lives in the same command tree as everything else, so
    * there is one place to look. The server does nothing but relay the request to the player who
    * asked.
    */
   private static int hud(CommandContext<CommandSourceStack> context, String mode) {
      ServerPlayer player = ((CommandSourceStack)context.getSource()).getPlayer();
      if (player == null) {
         ((CommandSourceStack)context.getSource()).sendFailure(Component.literal("The status panel is per-player; run this as a player."));
         return 0;
      }
      ServerPlayNetworking.send(player, DiagnosticCapturePayload.hud(mode));
      return 1;
   }

   private static int diagnosticYear(CommandContext<CommandSourceStack> context) {
      return diagnosticYear(context, IntegerArgumentType.getInteger(context, "seconds"));
   }

   private static int diagnosticYear(CommandContext<CommandSourceStack> context, int seconds) {
      ServerPlayer player = commandPlayer(context);
      if (player == null) {
         return 0;
      } else {
         long now = System.currentTimeMillis();
         SeasonDebugController.startDiagnosticYear(seconds, now);
         SeasonSnapshot snapshot = SeasonEngine.refresh(now);
         SeasonalWorldReconciler.queuePlayerVicinityUrgent(((CommandSourceStack)context.getSource()).getServer());
         TeslesSeasons.broadcastSeason(((CommandSourceStack)context.getSource()).getServer(), snapshot, true);
         ServerDiagnosticSampler.begin(player, seconds);
         ServerPlayNetworking.send(player, DiagnosticCapturePayload.year(seconds, diagnosticServerSummary()));
         ((CommandSourceStack)context.getSource())
            .sendSuccess(
               () -> Component.literal("Started diagnostic year (" + seconds + "s). Client will capture season checkpoints and zip them automatically."), true
            );
         return 1;
      }
   }

   private static ServerPlayer commandPlayer(CommandContext<CommandSourceStack> context) {
      try {
         return ((CommandSourceStack)context.getSource()).getPlayerOrException();
      } catch (CommandSyntaxException var2) {
         ((CommandSourceStack)context.getSource()).sendFailure(Component.literal("This diagnostic command must be run by a player client."));
         return null;
      }
   }

   private static String diagnosticServerSummary() {
      SeasonSnapshot s = SeasonEngine.current();
      return "TeslesSeasons diagnostic server snapshot\nseason="
         + s.season()
         + " phase="
         + s.phase()
         + " progress="
         + s.phaseProgress()
         + "\nchannels: autumn="
         + s.autumnColor()
         + " leaves="
         + s.leafRetention()
         + " flowers="
         + s.flowerRetention()
         + " mushrooms="
         + s.mushroomRetention()
         + " dormancy="
         + s.groundDormancy()
         + " snow="
         + s.snowCover()
         + " spring="
         + s.springFreshness()
         + "\nweather="
         + SeasonWeatherController.currentWeather().id()
         + "\n"
         + SeasonalWorldReconciler.status()
         + "\n"
         + VoxyServerBackfillBridge.status()
         + "\nvoxyBlend="
         + TeslesSeasons.CONFIG.voxySnowBlendStartBlocks
         + ".."
         + TeslesSeasons.CONFIG.voxySnowBlendEndBlocks
         + "\nbackgroundRadiusChunks="
         + TeslesSeasons.CONFIG.backgroundReconcileRadiusChunks
         + "\npreSendProjection="
         + TeslesSeasons.CONFIG.preSendSeasonProjection
         + "\n";
   }

   private static int weather(CommandContext<CommandSourceStack> context) {
      String raw = StringArgumentType.getString(context, "type");
      if ("auto".equalsIgnoreCase(raw)) {
         SeasonWeatherController.setForcedWeather(null);
         ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal("TESLES weather returned to automatic seasonal selection."), true);
         return 1;
      } else {
         TeslesWeatherType type = TeslesWeatherType.fromId(raw);
         if (type == null) {
            ((CommandSourceStack)context.getSource())
               .sendFailure(
                  Component.literal(
                     "Unknown weather type. Use auto, clear, cloudy, drizzle, rain, heavy_rain, thunderstorm, light_snow, snow, heavy_snow or blizzard."
                  )
               );
            return 0;
         } else {
            SeasonWeatherController.setForcedWeather(type);
            ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal("Forced TESLES weather: " + type.id()), true);
            return 1;
         }
      }
   }

   private static int voxyStatus(CommandContext<CommandSourceStack> context) {
      ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal(VoxyServerBackfillBridge.status()), false);
      return 1;
   }

   private static int voxyBackfill(CommandContext<CommandSourceStack> context) {
      String result = VoxyServerBackfillBridge.requestBackfill((CommandSourceStack)context.getSource());
      ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal(result), true);
      return result.startsWith("Started") ? 1 : 0;
   }

   private static int reconcile(CommandContext<CommandSourceStack> context) {
      SeasonalWorldReconciler.queueAllLoadedUrgent();
      ((CommandSourceStack)context.getSource())
         .sendSuccess(() -> Component.literal("Queued every currently loaded overworld chunk for immediate snow + flora + leaf reconciliation."), true);
      return 1;
   }

   private static int clear(CommandContext<CommandSourceStack> context) {
      SeasonDebugController.clear();
      SeasonSnapshot snapshot = SeasonEngine.refresh(System.currentTimeMillis());
      SeasonalWorldReconciler.queuePlayerVicinityUrgent(((CommandSourceStack)context.getSource()).getServer());
      TeslesSeasons.broadcastSeason(((CommandSourceStack)context.getSource()).getServer(), snapshot, true);
      ((CommandSourceStack)context.getSource())
         .sendSuccess(() -> Component.literal("TeslesSeasons debug/timelapse override cleared; real calendar restored."), true);
      return 1;
   }

   private static int timelapse(CommandContext<CommandSourceStack> context) {
      int seconds = IntegerArgumentType.getInteger(context, "seconds");
      long now = System.currentTimeMillis();
      SeasonDebugController.startYearLoop(seconds, now);
      SeasonSnapshot snapshot = SeasonEngine.refresh(now);
      SeasonalWorldReconciler.queuePlayerVicinityUrgent(((CommandSourceStack)context.getSource()).getServer());
      TeslesSeasons.broadcastSeason(((CommandSourceStack)context.getSource()).getServer(), snapshot, true);
      ((CommandSourceStack)context.getSource())
         .sendSuccess(
            () -> Component.literal(
               "Started looping TESLES year: SUMMER -> AUTUMN -> WINTER -> SPRING -> SUMMER, "
                  + seconds
                  + " seconds per full year. Use /teslesseasons timelapse stop to stop."
            ),
            true
         );
      return 1;
   }

   private static int forceSeason(CommandContext<CommandSourceStack> context) {
      Season season = parseSeason(context, "season");
      if (season == null) {
         return 0;
      } else {
         SeasonDebugController.forceSeason(season);
         SeasonSnapshot snapshot = SeasonEngine.refresh(System.currentTimeMillis());
         SeasonalWorldReconciler.queuePlayerVicinityUrgent(((CommandSourceStack)context.getSource()).getServer());
         TeslesSeasons.broadcastSeason(((CommandSourceStack)context.getSource()).getServer(), snapshot, true);
         ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal("Forced stable season: " + season.name()), true);
         return 1;
      }
   }

   private static int forceDate(CommandContext<CommandSourceStack> context) {
      String raw = StringArgumentType.getString(context, "date");

      LocalDate date;
      try {
         date = LocalDate.parse(raw);
      } catch (DateTimeParseException var4) {
         ((CommandSourceStack)context.getSource()).sendFailure(Component.literal("Invalid date. Use YYYY-MM-DD, e.g. 2026-08-01."));
         return 0;
      }

      SeasonDebugController.forceDate(date, TeslesSeasons.CONFIG);
      SeasonSnapshot snapshot = SeasonEngine.refresh(System.currentTimeMillis());
      SeasonalWorldReconciler.queuePlayerVicinityUrgent(((CommandSourceStack)context.getSource()).getServer());
      TeslesSeasons.broadcastSeason(((CommandSourceStack)context.getSource()).getServer(), snapshot, true);
      ((CommandSourceStack)context.getSource()).sendSuccess(() -> Component.literal("Forced season calendar date: " + date), true);
      return 1;
   }

   private static int forcePhase(CommandContext<CommandSourceStack> context) {
      Season season = parseSeason(context, "season");
      if (season == null) {
         return 0;
      } else {
         CalendarPhase phase = parsePhase(context, "phase");
         if (phase == null) {
            return 0;
         } else {
            int percent = IntegerArgumentType.getInteger(context, "percent");
            SeasonDebugController.forcePhase(season, phase, percent / 100.0F);
            SeasonSnapshot snapshot = SeasonEngine.refresh(System.currentTimeMillis());
            SeasonalWorldReconciler.queuePlayerVicinityUrgent(((CommandSourceStack)context.getSource()).getServer());
            TeslesSeasons.broadcastSeason(((CommandSourceStack)context.getSource()).getServer(), snapshot, true);
            ((CommandSourceStack)context.getSource())
               .sendSuccess(() -> Component.literal("Forced " + season.name() + " " + phase.name() + " at " + percent + "% transition progress."), true);
            return 1;
         }
      }
   }

   private static int transition(CommandContext<CommandSourceStack> context) {
      Season from = parseSeason(context, "from");
      Season to = parseSeason(context, "to");
      if (from == null || to == null) {
         return 0;
      } else if (from == to) {
         ((CommandSourceStack)context.getSource()).sendFailure(Component.literal("Transition start and target season must be different."));
         return 0;
      } else {
         int seconds = IntegerArgumentType.getInteger(context, "seconds");
         long now = System.currentTimeMillis();
         SeasonDebugController.startTransition(from, to, seconds, now);
         SeasonSnapshot snapshot = SeasonEngine.refresh(now);
         SeasonalWorldReconciler.queuePlayerVicinityUrgent(((CommandSourceStack)context.getSource()).getServer());
         TeslesSeasons.broadcastSeason(((CommandSourceStack)context.getSource()).getServer(), snapshot, true);
         ((CommandSourceStack)context.getSource())
            .sendSuccess(
               () -> Component.literal("Started accelerated season transition " + from.name() + " -> " + to.name() + " over " + seconds + " seconds."), true
            );
         return 1;
      }
   }

   private static Season parseSeason(CommandContext<CommandSourceStack> context, String argument) {
      String raw = StringArgumentType.getString(context, argument);
      Season season = Season.parse(raw, null);
      if (season == null) {
         ((CommandSourceStack)context.getSource()).sendFailure(Component.literal("Invalid season '" + raw + "'. Use spring, summer, autumn or winter."));
      }

      return season;
   }

   private static CalendarPhase parsePhase(CommandContext<CommandSourceStack> context, String argument) {
      String raw = StringArgumentType.getString(context, argument);

      try {
         return CalendarPhase.valueOf(raw.trim().toUpperCase(Locale.ROOT));
      } catch (IllegalArgumentException var4) {
         ((CommandSourceStack)context.getSource()).sendFailure(Component.literal("Invalid phase '" + raw + "'. Use incoming, stable or outgoing."));
         return null;
      }
   }

   private static String pct(float value) {
      return Math.round(value * 100.0F) + "%";
   }

   private static String two(int value) {
      return value < 10 ? "0" + value : Integer.toString(value);
   }
}
