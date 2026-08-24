package fi.tesles.seasons.client;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.weather.TeslesWeatherType;
import fi.tesles.seasons.weather.WeatherSnapshot;
import net.minecraft.client.Minecraft;
import net.minecraft.core.particles.ParticleTypes;
import net.minecraft.server.level.ParticleStatus;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.levelgen.Heightmap.Types;

public final class CustomWeatherEffects {
   private static double smoothedIntensity;
   private static double smoothedWindX;
   private static double smoothedWindZ;

   private CustomWeatherEffects() {
   }

   public static void reset() {
      smoothedIntensity = 0.0;
      smoothedWindX = 0.0;
      smoothedWindZ = 0.0;
   }

   public static void tick(Minecraft client) {
      if (client.level != null && client.player != null && TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.customWeatherSystem) {
         WeatherSnapshot weather = ClientWeatherState.get();
         TeslesWeatherType type = weather.type();
         if (!type.isRain()) {
            client.level.setRainLevel(0.0F);
            client.level.setThunderLevel(0.0F);
         }

         double target = type.isSnow() ? weather.intensity() : 0.0;
         smoothedIntensity = smoothedIntensity + (target - smoothedIntensity) * 0.075;
         smoothedWindX = smoothedWindX + (weather.windX() - smoothedWindX) * 0.08;
         smoothedWindZ = smoothedWindZ + (weather.windZ() - smoothedWindZ) * 0.08;
         if (type.isSnow() && !(smoothedIntensity < 0.015)) {
            ParticleStatus status = (ParticleStatus)client.options.particles().get();
            double particleScale = status == ParticleStatus.MINIMAL ? 0.22 : (status == ParticleStatus.DECREASED ? 0.55 : 1.0);

            int base = switch (type) {
               case LIGHT_SNOW -> 5;
               case SNOW -> 10;
               case HEAVY_SNOW -> 18;
               case BLIZZARD -> 30;
               default -> 0;
            };
            int count = Math.max(1, (int)Math.round(base * particleScale * smoothedIntensity));
            RandomSource random = RandomSource.createThreadLocalInstance();
            double px = client.player.getX();
            double py = client.player.getY();
            double pz = client.player.getZ();
            double radius = type == TeslesWeatherType.BLIZZARD ? 30.0 : 24.0;
            double vertical = type == TeslesWeatherType.BLIZZARD ? 16.0 : 22.0;
            double windScale = type == TeslesWeatherType.BLIZZARD ? 2.25 : (type == TeslesWeatherType.HEAVY_SNOW ? 1.45 : 1.0);

            for (int i = 0; i < count; i++) {
               double angle = random.nextDouble() * Math.PI * 2.0;
               double distance = Math.sqrt(random.nextDouble()) * radius;
               double x = px + Math.cos(angle) * distance;
               double z = pz + Math.sin(angle) * distance;
               int surface = client.level.getHeight(Types.MOTION_BLOCKING, (int)Math.floor(x), (int)Math.floor(z));
               double y = Math.max(py + 4.0, surface + 3.0) + random.nextDouble() * vertical;
               if (y > py + 34.0) {
                  y = py + 34.0 - random.nextDouble() * 3.0;
               }

               double drift = 0.72 + random.nextDouble() * 0.56;
               double vx = smoothedWindX * windScale * drift + random.nextGaussian() * 0.008;
               double vz = smoothedWindZ * windScale * drift + random.nextGaussian() * 0.008;
               double vy = -(0.035 + random.nextDouble() * 0.055);
               if (type == TeslesWeatherType.BLIZZARD) {
                  vy *= 0.72;
               }

               client.level.addParticle(ParticleTypes.SNOWFLAKE, x, y, z, vx, vy, vz);
            }

            if (type == TeslesWeatherType.BLIZZARD && status != ParticleStatus.MINIMAL) {
               int gusts = Math.max(1, count / 4);

               for (int i = 0; i < gusts; i++) {
                  double xx = px + (random.nextDouble() - 0.5) * 26.0;
                  double zx = pz + (random.nextDouble() - 0.5) * 26.0;
                  double yx = py + 1.5 + random.nextDouble() * 7.0;
                  client.level
                     .addParticle(
                        ParticleTypes.SNOWFLAKE,
                        xx,
                        yx,
                        zx,
                        smoothedWindX * 3.2 + random.nextGaussian() * 0.015,
                        -0.012 - random.nextDouble() * 0.022,
                        smoothedWindZ * 3.2 + random.nextGaussian() * 0.015
                     );
               }
            }
         }
      } else {
         smoothedIntensity *= 0.9;
      }
   }
}
