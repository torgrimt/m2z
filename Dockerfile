# Use a base image with bash and common utilities
FROM debian:bullseye-slim

# Set environment variables for non-interactive frontend
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies: mosquitto-clients (for mosquitto_sub), jq, zabbix-sender, ca-certificates, coreutils (for od), and perl
# Using Zabbix 6.0 LTS repository for Debian 11 (Bullseye) as an example.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    mosquitto-clients \
    jq \
    wget \
    gnupg \
    ca-certificates \
    coreutils \
    perl \
    libposix-strftime-compiler-perl \
    libsymbol-util-name-perl && \
    # Install zabbix-sender
    wget https://repo.zabbix.com/zabbix/6.0/debian/pool/main/z/zabbix-release/zabbix-release_6.0-4%2Bdebian11_all.deb && \
    dpkg -i zabbix-release_6.0-4+debian11_all.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends zabbix-sender && \
    # Clean up
    apt-get purge -y --auto-remove wget gnupg && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    rm zabbix-release_6.0-4+debian11_all.deb

# Set the working directory
WORKDIR /app

# Copy the Perl script into the container
COPY m2z.pl /app/mqtt_to_zabbix.pl

# Make the script executable
RUN chmod +x /app/mqtt_to_zabbix.pl

# --- Environment Variables (Defaults & Placeholders for zigbee2mqtt example) ---
# These can be overridden at runtime (docker run -e VAR=value)
# Ensure these match the placeholder style used in your script (e.g., __DEVICE_ID__)

# MQTT Configuration
ENV MQTT_BROKER_HOST="your_mqtt_broker_ip_or_hostname"
ENV MQTT_BROKER_PORT="1883"
# ENV MQTT_USERNAME="your_mqtt_user"
# ENV MQTT_PASSWORD="your_mqtt_password"
ENV MQTT_CLIENT_ID="mqtt-zabbix-bridge-perl"
ENV MQTT_TOPIC_PATTERN="zigbee2mqtt/+"
# For "zigbee2mqtt/DeviceName", DeviceName is the 2nd segment (index 1)
ENV MQTT_TOPIC_DEVICE_ID_SEGMENT_INDEX="1"

# Zabbix Configuration
ENV ZABBIX_SERVER_HOST="your_zabbix_server_ip_or_hostname"
ENV ZABBIX_SERVER_PORT="10051"
# Host name as configured in Zabbix UI
ENV ZABBIX_MONITORED_HOSTNAME="ZigbeeSensorsHost"

# Metric Configurations (Enable/Disable, Zabbix Key Template, JSON Field Path)
# __DEVICE_ID__ in Zabbix Key Template will be replaced by the Device ID from the MQTT topic.
ENV ENABLE_TEMP="true"
ENV ZABBIX_KEY_TEMP="z2m.temperature[__DEVICE_ID__]"
ENV JSON_FIELD_TEMP=".temperature"

ENV ENABLE_HUMID="true"
ENV ZABBIX_KEY_HUMID="z2m.humidity[__DEVICE_ID__]"
ENV JSON_FIELD_HUMID=".humidity"

ENV ENABLE_PRESSURE="true"
ENV ZABBIX_KEY_PRESSURE="z2m.pressure[__DEVICE_ID__]"
ENV JSON_FIELD_PRESSURE=".pressure"

ENV ENABLE_BATTERY="true"
ENV ZABBIX_KEY_BATTERY="z2m.battery[__DEVICE_ID__]"
ENV JSON_FIELD_BATTERY=".battery"

ENV ENABLE_LINKQUALITY="true"
ENV ZABBIX_KEY_LINKQUALITY="z2m.linkquality[__DEVICE_ID__]"
ENV JSON_FIELD_LINKQUALITY=".linkquality"

ENV ENABLE_VOLTAGE="true"
ENV ZABBIX_KEY_VOLTAGE="z2m.voltage[__DEVICE_ID__]"
ENV JSON_FIELD_VOLTAGE=".voltage"

ENV ENABLE_POWER_OUTAGE="true"
ENV ZABBIX_KEY_POWER_OUTAGE="z2m.power_outage_count[__DEVICE_ID__]"
ENV JSON_FIELD_POWER_OUTAGE=".power_outage_count"

# DEBUG, INFO, WARN, ERROR
ENV LOG_LEVEL="INFO"

# Run the Perl script when the container launches
CMD ["/app/mqtt_to_zabbix.pl"]
