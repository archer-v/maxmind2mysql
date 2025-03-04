# README

## Description
This script downloads and imports MaxMind GeoLite2 databases (ASN and Country) into MySQL.

## Requirements
- **Linux**
- **MySQL** (with access to load data via `LOAD DATA LOCAL INFILE`)
- **cURL**
- **unzip**
- **MaxMind GeoIP2 CSV Converter** (will be dowloaded by first script startup)

## Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/archer-v/maxmind2mysql.git
   cd maxmind2mysql
   ```

2. **Configure the settings**
   Create a `config.env` file in the script directory and add the following:
   
   ```bash
   maxmind_license_key="YOUR_KEY"
   maxmind_user_id="YOUR_ID"
   db_name="YOUR_DATABASE"
   db_user="USER"
   db_pass="PASSWORD"
   db_host="HOST"
   ```

3. **Grant execution permissions:**
   ```bash
   chmod +x maxmind2mysql.sh
   ```

4. **Run the script:**
   ```bash
   ./maxmind2mysql.sh
   ```

## How the Script Works

1. **Downloads** GeoLite2 database files (ASN and Country) from MaxMind.
2. **Extracts** CSV files from the archives.
3. **Converts** them into a MySQL-friendly format.
4. **Creates and updates** the `maxmind_ip_asn` and `maxmind_ip_countries` tables.
5. **Performs test queries** to verify data correctness.

## Table Descriptions

- **maxmind_ip_asn**: Contains ASN and IP range information.
- **maxmind_as_info**: Stores autonomous system names.
- **maxmind_ip_countries**: Links IP ranges to country codes.


## Automation with Cron

The script can be scheduled to run periodically using `cron`, ensuring that the database remains up to date.

Example crontab entry to run the script daily at midnight:

```bash
0 0 * * * /path/to/maxmind2mysql.sh
```
