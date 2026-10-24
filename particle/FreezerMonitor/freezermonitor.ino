/**************************************************************************
  Periodically publishes temperature and humidity data to Particle Cloud.

  Based on original code by:
   Priyanka Makin @ SparkFun Electronics
   Original Creation Date: March 31, 2020
   SparkFun labored with love to create this code. Feel like supporting open
   source hardware? Buy a board from SparkFun! https://www.sparkfun.com/products/16618
   This code is lemonadeware; if you see me (or any other SparkFun employee)
   at the local, and you've found our code helpful, please buy us a round!
   Distributed as-is; no warranty is given.
 **************************************************************************/
#include <Wire.h>

#include <SparkFun_Qwiic_Humidity_AHT20.h> //Click here to get the library: http://librarymanager/All#Qwiic_Humidity_AHT20 by SparkFun
AHT20 humiditySensor;

void setup()
{
  Wire.begin(); //Join I2C bus

  //Check if the AHT20 will acknowledge
  if (humiditySensor.begin() == false)
  {
    Particle.publish("error", "AHT20 not detected. Please check wiring. Freezing.");
    while (1);
  }
  Particle.publish("info", "AHT20 acknowledged.");
}

void loop()
{
  //If a new measurement is available
  if (humiditySensor.available() == true)
  {
    //Get the new temperature and humidity value
    float temperature = humiditySensor.getTemperature();
    float temperature_f = temperature*1.8+32;
    float humidity = humiditySensor.getHumidity();

    //Print the results
    Particle.publish("temp_data", String::format("{\"temp_c\": %.1f, \"temp_f\": %.1f, \"humidity\": %.1f}", temperature, temperature_f, humidity));
  }

  //The AHT20 can respond with a reading every ~50ms. However, increased read time can cause the IC to heat around 1.0C above ambient.
  //The datasheet recommends reading every 2 seconds.  Anything much more frequent than every 60 seconds will use up all the capacity on a
  //free Particle account, if that's a concern.
  delay(30000);
}