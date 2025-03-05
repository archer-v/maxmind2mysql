#!/bin/bash
# Fetch maxmind data files and update local mysql tables

# change working dir
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(realpath "$SCRIPT_DIR")"
cd $SCRIPT_DIR

source ./config.env

#maxmind_license_key=""
#maxmind_user_id=""
maxmind_asn_file="geolite2-asn-csv.zip"
maxmind_country_file="geolite2-country-csv.zip"
files_cache_age=864000
geoip_converter_bin="geoip2-csv-converter"

asn_csv="GeoLite2-ASN-Blocks-IPv4.csv"
country_dict_csv="GeoLite2-Country-Locations-en.csv"
ipv4_country_csv="GeoLite2-Country-Blocks-IPv4.csv"

force_update=0

#db_name=""
#db_user=""
#db_pass=""
#db_host=""
data_dir="unpacked"
download_url_prefix="https://${maxmind_user_id}:${maxmind_license_key}@download.maxmind.com/geoip/databases"

[ -d "$data_dir" ] || force_update=1

mkdir -p "$data_dir"

sql_asn="
CREATE TABLE IF NOT EXISTS maxmind_ip_asn (
    network VARBINARY(16) NOT NULL,
    prefix INT NOT NULL,
    network_start varbinary(16) not null,
    network_end varbinary(16) not null,
    asn INT,
    PRIMARY KEY(network, prefix),
    index(network_start),
    index(network_end)
);


CREATE TABLE IF NOT EXISTS maxmind_ip_asn_tmp LIKE maxmind_ip_asn;

TRUNCATE TABLE maxmind_ip_asn_tmp;

LOAD DATA LOCAL INFILE '$data_dir/$asn_csv'
INTO TABLE maxmind_ip_asn_tmp
FIELDS TERMINATED BY ',' ENCLOSED BY '\"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(@network_cidr, @network_start, @network_end, asn, @dummy)
SET 
    network = INET6_ATON(SUBSTRING_INDEX(@network_cidr, '/', 1)),
    prefix = CAST(SUBSTRING_INDEX(@network_cidr, '/', -1) AS UNSIGNED),
    network_start = unhex(@network_start),
    network_end = unhex(@network_end);

DROP TABLE maxmind_ip_asn;
RENAME TABLE maxmind_ip_asn_tmp TO maxmind_ip_asn;

CREATE TABLE IF NOT EXISTS maxmind_as_info (
    asn INT PRIMARY KEY,
    name VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS maxmind_as_info_tmp LIKE maxmind_as_info;

LOAD DATA LOCAL INFILE '$data_dir/$asn_csv'
IGNORE INTO TABLE maxmind_as_info_tmp
FIELDS TERMINATED BY ',' ENCLOSED BY '\"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(@network_cidr, @network_start, @network_end, asn, name);

DROP TABLE maxmind_as_info;
RENAME TABLE maxmind_as_info_tmp TO maxmind_as_info;
"

sql_country="
CREATE TABLE IF NOT EXISTS maxmind_country_info_tmp (
    geoname_id INT PRIMARY KEY,
    country_iso_code CHAR(2) NOT NULL
);
TRUNCATE TABLE maxmind_country_info_tmp;

LOAD DATA LOCAL INFILE '$data_dir/$country_dict_csv'
INTO TABLE maxmind_country_info_tmp
FIELDS TERMINATED BY ',' ENCLOSED BY '\"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(geoname_id, @locale_code, @continent_code, @continent_name, country_iso_code);

CREATE TABLE IF NOT EXISTS maxmind_ip_countries_tmp (
    network VARBINARY(16) NOT NULL,
    prefix INT NOT NULL,
    network_start varbinary(16) not null,
    network_end varbinary(16) not null,
    country_id INT,
    PRIMARY KEY(network, prefix),
    index(network_start),
    index(network_end)
);

TRUNCATE TABLE maxmind_ip_countries_tmp;

LOAD DATA LOCAL INFILE '$data_dir/$ipv4_country_csv'
INTO TABLE maxmind_ip_countries_tmp
FIELDS TERMINATED BY ',' ENCLOSED BY '\"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(@network_cidr, @network_start, @network_end, @dummy, country_id)
SET 
    network = INET6_ATON(SUBSTRING_INDEX(@network_cidr, '/', 1)),
    prefix = CAST(SUBSTRING_INDEX(@network_cidr, '/', -1) AS UNSIGNED),
    network_start = unhex(@network_start),
    network_end = unhex(@network_end);

CREATE TABLE IF NOT EXISTS maxmind_ip_countries (
    network VARBINARY(16) NOT NULL,
    prefix INT NOT NULL,
    network_start varbinary(16) not null,
    network_end varbinary(16) not null,
    asn int,
    country_iso_code CHAR(2),
    PRIMARY KEY(network, prefix),
    index(network_start),
    index(network_end)
);

TRUNCATE TABLE maxmind_ip_countries;

INSERT INTO maxmind_ip_countries (network, prefix, network_start, network_end, country_iso_code)
SELECT 
    ir.network,
    ir.prefix,
    ir.network_start,
    ir.network_end,
    ci.country_iso_code
FROM maxmind_ip_countries_tmp AS ir
LEFT JOIN maxmind_country_info_tmp AS ci
    ON ir.country_id = ci.geoname_id;

DROP TABLE IF EXISTS maxmind_ip_countries_tmp;
DROP TABLE IF EXISTS maxmind_country_info_tmp;
"

sql_test_country="
select CONCAT(INET6_NTOA(network), '/', prefix) as network, country_iso_code
from (
  select *
  from maxmind_ip_countries
  where
    length(inet6_aton('214.0.0.0')) = length(network_start)
    and inet6_aton('214.0.0.0') >= network_start
  order by network_start desc
  limit 1
) net
where inet6_aton('214.0.0.0') <= network_end;
"

sql_test_asn="
select CONCAT(INET6_NTOA(network), '/', prefix) as network, asn
from (
  select *
  from maxmind_ip_asn
  where
    length(inet6_aton('214.0.0.0')) = length(network_start)
    and inet6_aton('214.0.0.0') >= network_start
  order by network_start desc
  limit 1
) net
where inet6_aton('214.0.0.0') <= network_end;
"

file_download() {
    download_url=$1
    file_name=$2
    file_age=0
    min_file_size=300
    max_file_age=$files_cache_age
    orig_file_size=0
    if [ -e ${file_name} ]; then
        orig_file_size=`stat -c "%s" ${file_name}`
        if [ ${orig_file_size} -ge ${min_file_size} ]; then 
            file_age=$((`date +%s`-`stat -c "%Y" ${file_name}`))
        fi
    fi

    if [ ${file_age} -eq 0 -o ${file_age} -ge ${max_file_age} ]; then
        echo "Downloading $file_name by url: $download_url"
        curl -L "$download_url" -o $file_name
    else 
        echo "File $file_name downloading is skipped, cause file isn't old enough"
        return 2
    fi

    if [ ! -e ${file_name} -o `stat -c "%s" ${file_name}` -le ${min_file_size} ]; then
        echo "ERROR: download error $file_name"
        mv -f $file_name "$file_name.download_error"
        return 1
    fi

    if [ `stat -c "%s" ${file_name}` -eq ${orig_file_size} ]; then
        return 2
    fi

    return 0
}

download_geoip_converter() {
    if [ -e ${geoip_converter_bin} ]; then
       return
    fi

    file_pattern="386.tar.gz"
    latest_release_url="https://api.github.com/repos/maxmind/geoip2-csv-converter/releases/latest"
    response=$(curl -s "$latest_release_url")
    download_url=$(echo "$response" | grep -oE '"browser_download_url": *"[^"]+' | grep "$file_pattern" | head -n 1 | sed 's/"browser_download_url": "//')
    if [ -z "$download_url" ]; then
        echo "can't download geoip2-csv-converter file: file not found!"
        exit 1
    fi
    file_download "$download_url" "$file_pattern"
    d_result=$?
    if [ ${d_result} -eq 1 ]; then
      exit 1
    fi

    tar --strip-components=1 -xzf $file_pattern --wildcards "**/${geoip_converter_bin}"

    if [ ! -e ${geoip_converter_bin} ]; then
       echo "can't download geoip2-csv-converter file: something wrong with tar.gz file!"
       return
    fi

    rm "$file_pattern"
}

get_org_networks() {
    org=$1
    filename=$2
    echo "Gathering networks for org ${org}"
    whois -h whois.arin.net "+ n / ${org} " | grep CIDR | grep -Eo "([0-9.]+){4}/[0-9]+" >> $filename
}

get_as_networks() {
    as=$1
    filename=$2
    echo "Gathering networks for AS${as}"
    whois -h whois.radb.net -- '-i origin AS'$as | grep -Eo "([0-9.]+){4}/[0-9]+" >> $filename
}

get_org_ass() {
    org=$1
    echo $(unzip -p ${maxmind_asn_file} `unzip -l ${maxmind_asn_file} |grep -e GeoLite2-ASN-Blocks-IPv4.csv | sed 's/^.\{30\}//g'` | grep -i ${org} | cut -d"," -f2 | sort -u)
}

check_file_in_arch() {
    file=$1
    arch=$2
    if [[ ! -f "$data_dir/$file" ]]; then
       echo "Error: file $file isn't found in $arch"
       exit 1
    fi
}

perform_sql_op() {
    echo "Performing SQL request..."
    sql_result=$(echo "$1" | mysql -h"$db_host" -u"$db_user" -p"$db_pass" "$db_name" -N)
    echo "$sql_result"
}

convert_csv() {
   file=$1
   echo "Converting the file $file into a format with network_start/network_end fields suitable for importing into MySQL"
   ./geoip2-csv-converter -block-file "$data_dir/$file" -include-hex-range -include-cidr -output-file "$data_dir/$file-t"
   mv -f "$data_dir/$file-t" "$data_dir/$file"
}

update_asn_data() {
    unzip -j -o "$maxmind_asn_file" -d "$data_dir"
    check_file_in_arch $asn_csv $maxmind_asn_file
    convert_csv $asn_csv

    perform_sql_op "$sql_asn"
}

update_country_data() {
    unzip -j -o "$maxmind_country_file" -d "$data_dir"
    check_file_in_arch $country_dict_csv $maxmind_country_file
    check_file_in_arch $ipv4_country_csv $maxmind_country_file
    convert_csv $ipv4_country_csv

    perform_sql_op "$sql_country"
}

  download_geoip_converter

  if [ -z "$maxmind_license_key" -o -z "$maxmind_user_id" ]; then
      echo "maxmind credentials isn't defined in ./config.env"
      exit 1
  fi

  file=$maxmind_asn_file
  file_download "${download_url_prefix}/GeoLite2-ASN-CSV/download?suffix=zip" $file
  d_result=$?
  if [ ${d_result} -eq 1 ]; then
    exit 1
  fi

  if [ ${d_result} -eq 0 ]; then
      force_update=1
  else 
      echo "$file file isn't changed"
  fi

  file=$maxmind_country_file
  file_download "${download_url_prefix}/GeoLite2-Country-CSV/download?suffix=zip" $file
  d_result=$?
  if [ ${d_result} -eq 1 ]; then
      exit 1
  fi

  if [ ${d_result} -eq 0 ]; then
      force_update=1
  else 
      echo "$file file isn't changed"
  fi

  if [ ${force_update} -eq 0 ]; then
      echo "$file files isn't changed, update skipped"
      exit 0
  fi

  echo "Performing import of updated data from $maxmind_asn_file"
  update_asn_data

  echo "Performing import of updated data from $maxmind_country_file"
  update_country_data

  echo "Testing..."
  perform_sql_op "$sql_test_country"
  if [[ $? -ne 0 || $(echo "$sql_result" | wc -l) -ne 1 ]]; then
    echo "Test failed 1"
      exit 1
  fi
  perform_sql_op "$sql_test_asn"
  if [[ $? -ne 0 || $(echo "$sql_result" | wc -l) -ne 1 ]]; then
      echo "Test failed 2"
      exit 1
  fi

  echo "Done"
