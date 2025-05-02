#!/usr/bin/env perl

use strict;
use warnings;
use POSIX qw(strftime);
use IPC::Open3;
use Symbol qw(gensym);

# --- Configuration from Environment Variables (with defaults) ---
my $MQTT_BROKER_HOST = $ENV{MQTT_BROKER_HOST} || "localhost";
my $MQTT_BROKER_PORT = $ENV{MQTT_BROKER_PORT} || "1883";
my $MQTT_USERNAME = $ENV{MQTT_USERNAME} || "";
my $MQTT_PASSWORD = $ENV{MQTT_PASSWORD} || "";
my $MQTT_CLIENT_ID = $ENV{MQTT_CLIENT_ID} || "mqtt-zabbix-bridge-perl-$$"; # $$ adds PID for uniqueness
my $MQTT_TOPIC_PATTERN = $ENV{MQTT_TOPIC_PATTERN} || "zigbee2mqtt/+"; # Example: zigbee2mqtt/DeviceName
my $MQTT_TOPIC_DEVICE_ID_SEGMENT_INDEX = $ENV{MQTT_TOPIC_DEVICE_ID_SEGMENT_INDEX} || "1"; # 0-indexed

my $ZABBIX_SERVER_HOST = $ENV{ZABBIX_SERVER_HOST} || "localhost";
my $ZABBIX_SERVER_PORT = $ENV{ZABBIX_SERVER_PORT} || "10051";
my $ZABBIX_MONITORED_HOSTNAME = $ENV{ZABBIX_MONITORED_HOSTNAME} || "MQTT_Perl_Sensors";

# Zabbix Item Key Templates & JSON fields for extraction
# Placeholder __DEVICE_ID__ for robustness
my $ENABLE_TEMP = $ENV{ENABLE_TEMP} || "true";
my $ZABBIX_KEY_TEMP = $ENV{ZABBIX_KEY_TEMP} || "z2m.temperature[__DEVICE_ID__]";
my $JSON_FIELD_TEMP = $ENV{JSON_FIELD_TEMP} || ".temperature";

my $ENABLE_HUMID = $ENV{ENABLE_HUMID} || "true";
my $ZABBIX_KEY_HUMID = $ENV{ZABBIX_KEY_HUMID} || "z2m.humidity[__DEVICE_ID__]";
my $JSON_FIELD_HUMID = $ENV{JSON_FIELD_HUMID} || ".humidity";

my $ENABLE_PRESSURE = $ENV{ENABLE_PRESSURE} || "true";
my $ZABBIX_KEY_PRESSURE = $ENV{ZABBIX_KEY_PRESSURE} || "z2m.pressure[__DEVICE_ID__]";
my $JSON_FIELD_PRESSURE = $ENV{JSON_FIELD_PRESSURE} || ".pressure";

my $ENABLE_BATTERY = $ENV{ENABLE_BATTERY} || "true";
my $ZABBIX_KEY_BATTERY = $ENV{ZABBIX_KEY_BATTERY} || "z2m.battery[__DEVICE_ID__]";
my $JSON_FIELD_BATTERY = $ENV{JSON_FIELD_BATTERY} || ".battery";

my $ENABLE_LINKQUALITY = $ENV{ENABLE_LINKQUALITY} || "true";
my $ZABBIX_KEY_LINKQUALITY = $ENV{ZABBIX_KEY_LINKQUALITY} || "z2m.linkquality[__DEVICE_ID__]";
my $JSON_FIELD_LINKQUALITY = $ENV{JSON_FIELD_LINKQUALITY} || ".linkquality";

my $ENABLE_VOLTAGE = $ENV{ENABLE_VOLTAGE} || "true";
my $ZABBIX_KEY_VOLTAGE = $ENV{ZABBIX_KEY_VOLTAGE} || "z2m.voltage[__DEVICE_ID__]";
my $JSON_FIELD_VOLTAGE = $ENV{JSON_FIELD_VOLTAGE} || ".voltage";

my $ENABLE_POWER_OUTAGE = $ENV{ENABLE_POWER_OUTAGE} || "true";
my $ZABBIX_KEY_POWER_OUTAGE = $ENV{ZABBIX_KEY_POWER_OUTAGE} || "z2m.power_outage_count[__DEVICE_ID__]";
my $JSON_FIELD_POWER_OUTAGE = $ENV{JSON_FIELD_POWER_OUTAGE} || ".power_outage_count";

my $LOG_LEVEL = $ENV{LOG_LEVEL} || "INFO"; # DEBUG, INFO, WARN, ERROR

# --- Helper Functions ---
sub log_msg {
    my ($level, $message) = @_;
    my $requested_level_num;
    my $current_level_num;

    if ($LOG_LEVEL eq "DEBUG") { $requested_level_num = 0; }
    elsif ($LOG_LEVEL eq "INFO") { $requested_level_num = 1; }
    elsif ($LOG_LEVEL eq "WARN") { $requested_level_num = 2; }
    elsif ($LOG_LEVEL eq "ERROR") { $requested_level_num = 3; }
    else { $requested_level_num = 1; }

    if ($level eq "DEBUG") { $current_level_num = 0; }
    elsif ($level eq "INFO") { $current_level_num = 1; }
    elsif ($level eq "WARN") { $current_level_num = 2; }
    elsif ($level eq "ERROR") { $current_level_num = 3; }
    else { $current_level_num = 1; }

    if ($current_level_num >= $requested_level_num) {
        my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
        print "$timestamp - $level - $message\n";
    }
}

sub send_to_zabbix {
    my ($item_host, $item_key, $item_value) = @_;

    if (!defined($item_value) || $item_value eq "" || $item_value eq "null") {
        log_msg("DEBUG", "SEND_TO_ZABBIX: Skipping Zabbix send for Key='$item_key', value is null or empty.");
        return;
    }

    log_msg("DEBUG", "SEND_TO_ZABBIX: Preparing to send: Host='$item_host', Key='$item_key', Value='$item_value'");

    my $zabbix_sender_cmd = "zabbix_sender -z \"$ZABBIX_SERVER_HOST\" -p \"$ZABBIX_SERVER_PORT\" -s \"$item_host\" -k \"$item_key\" -o \"$item_value\"";

    log_msg("DEBUG", "SEND_TO_ZABBIX: Executing: $zabbix_sender_cmd");

    my $output = `$zabbix_sender_cmd 2>&1`;
    my $exit_code = $? >> 8;

    if ($exit_code == 0 && $output =~ /failed: 0/) {
        log_msg("INFO", "SEND_TO_ZABBIX: Successfully sent: Key='$item_key', Value='$item_value'. Output: $output");
    } else {
        log_msg("ERROR", "SEND_TO_ZABBIX: Failed to send: Key='$item_key', Value='$item_value'. ExitCode: $exit_code, Output: $output");
    }
}

sub process_metric {
    my ($device_id, $json_payload, $enable_flag, $key_template, $json_field, $metric_name) = @_;

    if ($enable_flag ne "true") {
        log_msg("DEBUG", "PROCESS_METRIC ($metric_name): Processing disabled.");
        return;
    }

    my $value = `echo '$json_payload' | jq -r '$json_field // ""'`;
    chomp($value);

    if (defined($value) && $value ne "" && $value ne "null") {
        log_msg("DEBUG", "PROCESS_METRIC ($metric_name): Device ID to use for substitution: '$device_id'");
        log_msg("DEBUG", "PROCESS_METRIC ($metric_name): Key template before substitution: '$key_template'");

        if ($LOG_LEVEL eq "DEBUG") {
            log_msg("DEBUG", "PROCESS_METRIC ($metric_name): Hexdump of key_template pre-subst:");
            system("printf \"%s\" \"$key_template\" | od -An -t c -t x1");
            log_msg("DEBUG", "PROCESS_METRIC ($metric_name): Hexdump of device_id pre-subst:");
            system("printf \"%s\" \"$device_id\" | od -An -t c -t x1");
        }

        my $final_key = $key_template;
        $final_key =~ s/__DEVICE_ID__/$device_id/g;

        log_msg("DEBUG", "PROCESS_METRIC ($metric_name): Key template after Perl substitution: '$final_key'");
        if ($LOG_LEVEL eq "DEBUG") {
            log_msg("DEBUG", "PROCESS_METRIC ($metric_name): Hexdump of final_key post-subst:");
            system("printf \"%s\" \"$final_key\" | od -An -t c -t x1");
        }

        log_msg("DEBUG", "PROCESS_METRIC ($metric_name): Extracted '$value' for '$device_id'. Sending with Zabbix key '$final_key'.");
        send_to_zabbix($ZABBIX_MONITORED_HOSTNAME, $final_key, $value);
    } else {
        log_msg("DEBUG", "PROCESS_METRIC ($metric_name): No value found (field: $json_field) for device '$device_id' in payload: $json_payload");
    }
}

# --- Sanity Checks ---
sub check_command {
    my ($cmd, $name) = @_;
    my $check = `which $cmd 2>/dev/null`;
    if (!$check) {
        log_msg("ERROR", "$name command not found. Please install $name.");
        exit 1;
    }
}

check_command("mosquitto_sub", "mosquitto_sub");
check_command("jq", "jq");
check_command("zabbix_sender", "zabbix_sender");
check_command("awk", "awk");
check_command("od", "od");

if (!$ZABBIX_MONITORED_HOSTNAME) {
    log_msg("ERROR", "ZABBIX_MONITORED_HOSTNAME is not set. This is required.");
    exit 1;
}

# --- Main Logic ---
log_msg("INFO", "MAIN: MQTT to Zabbix bridge (Perl) starting...");
log_msg("INFO", "MAIN: Connecting to MQTT Broker: $MQTT_BROKER_HOST:$MQTT_BROKER_PORT");
log_msg("INFO", "MAIN: Subscribing to topic pattern: $MQTT_TOPIC_PATTERN");
log_msg("INFO", "MAIN: Zabbix Server: $ZABBIX_SERVER_HOST:$ZABBIX_SERVER_PORT");
log_msg("INFO", "MAIN: Zabbix Monitored Hostname: $ZABBIX_MONITORED_HOSTNAME");
log_msg("INFO", "MAIN: Device ID will be extracted from topic segment index: $MQTT_TOPIC_DEVICE_ID_SEGMENT_INDEX");

while (1) {
    my $mqtt_cmd = "mosquitto_sub -h \"$MQTT_BROKER_HOST\" -p \"$MQTT_BROKER_PORT\" -t \"$MQTT_TOPIC_PATTERN\" -F \"%t %p\" --quiet -i \"$MQTT_CLIENT_ID\"";

    if ($MQTT_USERNAME) {
        $mqtt_cmd .= " -u \"$MQTT_USERNAME\"";
    }
    if ($MQTT_PASSWORD) {
        $mqtt_cmd .= " -P \"$MQTT_PASSWORD\"";
    }

    log_msg("DEBUG", "MAIN: Executing MQTT command: $mqtt_cmd");

    # Use open3 to capture both stdout and stderr
    my $pid;
    my $mqtt_in = gensym();
    my $mqtt_out = gensym();
    my $mqtt_err = gensym();

    $pid = open3($mqtt_in, $mqtt_out, $mqtt_err, $mqtt_cmd);

    while (my $line = <$mqtt_out>) {
        chomp($line);
        log_msg("DEBUG", "MAIN_LOOP: Raw line from mosquitto_sub: '$line'");

        if ($line =~ /^\s*$/) {
            log_msg("DEBUG", "MAIN_LOOP: Received empty or whitespace-only line from mosquitto_sub, skipping.");
            next;
        }

        my ($topic, $payload);
        if ($line =~ /^(.*?)\s(.*)$/) {
            $topic = $1;
            $payload = $2;
        } else {
            $topic = $line;
            $payload = "";
            log_msg("DEBUG", "MAIN_LOOP: Line appeared to have no spaces. Assuming Topic: '$topic', and Payload is empty.");
        }

        log_msg("INFO", "MAIN_LOOP: Parsed: Topic='$topic', Payload='$payload'");

        my $device_id = "";
        if ($topic) {
            my @topic_parts = split('/', $topic);
            $device_id = $topic_parts[$MQTT_TOPIC_DEVICE_ID_SEGMENT_INDEX] if defined $topic_parts[$MQTT_TOPIC_DEVICE_ID_SEGMENT_INDEX];
        }

        if (!$device_id) {
            if (!$topic) {
                log_msg("WARN", "MAIN_LOOP: Topic string was empty after parsing. Original line: '$line'. Skipping message.");
            } else {
                log_msg("WARN", "MAIN_LOOP: Could not extract Device ID from topic '$topic' using segment index $MQTT_TOPIC_DEVICE_ID_SEGMENT_INDEX. Original line: '$line'. Skipping message.");
            }
            next;
        }
        log_msg("DEBUG", "MAIN_LOOP: Extracted Device ID: '$device_id'");

        # Check if payload is valid JSON
        my $json_check = `echo '$payload' | jq -e . 2>/dev/null`;
        my $json_valid = $? == 0;

        if (!$json_valid) {
            log_msg("WARN", "MAIN_LOOP: Payload for topic '$topic' is not valid JSON. Payload: '$payload'. Skipping.");
            next;
        }

        process_metric($device_id, $payload, $ENABLE_TEMP, $ZABBIX_KEY_TEMP, $JSON_FIELD_TEMP, "Temperature");
        process_metric($device_id, $payload, $ENABLE_HUMID, $ZABBIX_KEY_HUMID, $JSON_FIELD_HUMID, "Humidity");
        process_metric($device_id, $payload, $ENABLE_PRESSURE, $ZABBIX_KEY_PRESSURE, $JSON_FIELD_PRESSURE, "Pressure");
        process_metric($device_id, $payload, $ENABLE_BATTERY, $ZABBIX_KEY_BATTERY, $JSON_FIELD_BATTERY, "Battery");
        process_metric($device_id, $payload, $ENABLE_LINKQUALITY, $ZABBIX_KEY_LINKQUALITY, $JSON_FIELD_LINKQUALITY, "LinkQuality");
        process_metric($device_id, $payload, $ENABLE_VOLTAGE, $ZABBIX_KEY_VOLTAGE, $JSON_FIELD_VOLTAGE, "Voltage");
        process_metric($device_id, $payload, $ENABLE_POWER_OUTAGE, $ZABBIX_KEY_POWER_OUTAGE, $JSON_FIELD_POWER_OUTAGE, "PowerOutageCount");
    }

    # Check if mosquitto_sub process ended
    my $err_line = <$mqtt_err>;
    if ($err_line) {
        log_msg("WARN", "MAIN: mosquitto_sub process error: $err_line");
    }

    log_msg("WARN", "MAIN: mosquitto_sub process ended. Retrying connection in 5 seconds...");
    close($mqtt_in);
    close($mqtt_out);
    close($mqtt_err);
    waitpid($pid, 0);
    sleep 5;
}