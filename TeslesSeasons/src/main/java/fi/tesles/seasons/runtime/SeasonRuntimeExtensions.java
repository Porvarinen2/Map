package fi.tesles.seasons.runtime;

import com.mojang.brigadier.builder.LiteralArgumentBuilder;
import fi.tesles.seasons.debug.SeasonDebugController;
import fi.tesles.seasons.weather.SeasonWeatherController;
import fi.tesles.seasons.weather.TeslesWeatherType;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.command.v2.CommandRegistrationCallback;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerTickEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents.ServerStopped;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.permissions.Permissions;

public final class SeasonRuntimeExtensions implements ModInitializer {
   private static boolean weatherDisabledDuringTimelapse;
   private static boolean weatherOverrideEngaged;
   private static TeslesWeatherType previousForcedWeather;

   public void onInitialize() {
      CommandRegistrationCallback.EVENT
         .register(
            (CommandRegistrationCallback)(dispatcher, registryAccess, environment) -> dispatcher.register(
               (LiteralArgumentBuilder)((LiteralArgumentBuilder)Commands.literal("teslesseasons")
                     .requires(source -> source.permissions().hasPermission(Permissions.COMMANDS_MODERATOR)))
                  .then(
                     ((LiteralArgumentBuilder)((LiteralArgumentBuilder)Commands.literal("timelapseweather")
                              .then(
                                 Commands.literal("off")
                                    .executes(
                                       ctx -> {
                                          weatherDisabledDuringTimelapse = true;
                                          updateWeatherOverride(((CommandSourceStack)ctx.getSource()).getServer());
                                          ((CommandSourceStack)ctx.getSource())
                                             .sendSuccess(
                                                () -> Component.literal("TESLES timelapse weather: OFF (forced clear while animated timelapse/debug is active)"),
                                                true
                                             );
                                          return 1;
                                       }
                                    )
                              ))
                           .then(Commands.literal("on").executes(ctx -> {
                              weatherDisabledDuringTimelapse = false;
                              updateWeatherOverride(((CommandSourceStack)ctx.getSource()).getServer());
                              ((CommandSourceStack)ctx.getSource())
                                 .sendSuccess(() -> Component.literal("TESLES timelapse weather: ON (normal seasonal weather)"), true);
                              return 1;
                           })))
                        .then(Commands.literal("status").executes(ctx -> {
                           String mode = weatherDisabledDuringTimelapse ? "OFF during timelapse" : "ON / normal";
                           ((CommandSourceStack)ctx.getSource()).sendSuccess(() -> Component.literal("TESLES timelapse weather: " + mode), false);
                           return 1;
                        }))
                  )
            )
         );
      ServerTickEvents.END_SERVER_TICK.register(SeasonRuntimeExtensions::updateWeatherOverride);
      ServerLifecycleEvents.SERVER_STOPPED.register((ServerStopped)server -> resetWeatherOverride());
   }

   private static void updateWeatherOverride(MinecraftServer server) {
      boolean animated = SeasonDebugController.hasAnimatedOverride();
      boolean shouldForceClear = weatherDisabledDuringTimelapse && animated;
      if (shouldForceClear) {
         if (!weatherOverrideEngaged) {
            previousForcedWeather = SeasonWeatherController.forcedWeather();
            weatherOverrideEngaged = true;
         }

         if (SeasonWeatherController.forcedWeather() != TeslesWeatherType.CLEAR) {
            SeasonWeatherController.setForcedWeather(TeslesWeatherType.CLEAR);
         }
      } else if (weatherOverrideEngaged) {
         SeasonWeatherController.setForcedWeather(previousForcedWeather);
         previousForcedWeather = null;
         weatherOverrideEngaged = false;
      }
   }

   private static void resetWeatherOverride() {
      if (weatherOverrideEngaged) {
         SeasonWeatherController.setForcedWeather(previousForcedWeather);
      }

      previousForcedWeather = null;
      weatherOverrideEngaged = false;
      weatherDisabledDuringTimelapse = false;
   }
}
