#!/bin/bash
##      .SYNOPSIS
##      Grafana Dashboard for Veeam Backup & Replication v12.3 - Using API to InfluxDB Script
## 
##      .DESCRIPTION
##      This Script will query the Veeam Backup & Replication API and send the data directly to InfluxDB, which can be used to present it to Grafana. 
##      The Script and the Grafana Dashboard it is provided as it is, and bear in mind you can not open support Tickets regarding this project. It is a Community Project
##	
##      .Notes
##      NAME:  veeam_backup_and_replication.sh
##      ORIGINAL NAME: veeam_backup_and_replication.sh
##      LASTEDIT: 04/02/2025
##      VERSION: 12.3.2
##      KEYWORDS: Veeam, , Backup, InfluxDB, Grafana
   
##      .Link
##      https://jorgedelacruz.es/
##      https://jorgedelacruz.uk/

##
# Configurations
##
# Endpoint URL for InfluxDB
veeamInfluxDBURL="http://YOURINFLUXSERVERIP" #Your InfluxDB Server, http://FQDN or https://FQDN if using SSL
veeamInfluxDBPort="8086" #Default Port
veeamInfluxDBBucket="veeam" # InfluxDB bucket name (not ID)
veeamInfluxDBToken="TOKEN" # InfluxDB access token with read/write privileges for the bucket
veeamInfluxDBOrg="ORG NAME" # InfluxDB organisation name (not ID)

# Endpoint URL for login action
veeamJobSessions="1000"
veeamUsername="YOURVBRUSER"
veeamPassword="YOURVBRPASSWORD"
veeamBackupServer="YOURVBRAPIPORT"
veeamBackupPort="9419" #Default Port
# API Version
veeamAPIVersion="1.2-rev0" # Set the API version here (e.g., 1.2-rev0)

# Get the bearer token and HTTP status code
response=$(curl -s -o response.json -w "%{http_code}" -X POST "https://$veeamBackupServer:$veeamBackupPort/api/oauth2/token" \
  -H "accept: application/json" \
  -H "x-api-version: $veeamAPIVersion" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=$veeamUsername&password=$veeamPassword" \
  -k)

veeamBearertmp=$(<response.json)
rm response.json
http_status=$response

case $http_status in
    200)
        veeamBearer=$(echo "$veeamBearertmp" | jq -r '.access_token')
        if [ -n "$veeamBearer" ] && [ "$veeamBearer" != "null" ]; then
            echo "Successfully obtained bearer token"
        else
            echo "Bearer token was not found in the response."
            exit 1
        fi
        ;;
    400)
        # Parse error message
        errorMessage=$(echo "$veeamBearertmp" | jq -r '.message')
        echo "Bad request: $errorMessage"
        exit 1
        ;;
    401)
        errorMessage=$(echo "$veeamBearertmp" | jq -r '.message')
        echo "Unauthorized: $errorMessage"
        exit 1
        ;;
    403)
        errorMessage=$(echo "$veeamBearertmp" | jq -r '.message')
        echo "Forbidden: $errorMessage"
        exit 1
        ;;
    500)
        errorMessage=$(echo "$veeamBearertmp" | jq -r '.message')
        echo "Internal server error: $errorMessage"
        exit 1
        ;;
    *)
        echo "An unexpected error occurred with HTTP status code: $http_status."
        exit 1
        ;;
esac

##
# Veeam Backup & Replication Information. This part will check VBR Information
##
veeamVBRURL="https://$veeamBackupServer:$veeamBackupPort/api/v1/serverInfo"
veeamVBRInfoUrl=$(curl -X GET $veeamVBRURL \
  -H "Authorization: Bearer $veeamBearer" \
  -H  "accept: application/json" \
  -H  "x-api-version: $veeamAPIVersion" \
  2>&1 -k --silent)

    veeamVBRId=$(echo "$veeamVBRInfoUrl" | jq --raw-output ".vbrId")
    veeamVBRName=$(echo "$veeamVBRInfoUrl" | jq --raw-output ".name" | awk '{gsub(/([ ,])/,"\\\\&");print}')
    veeamVBRVersion=$(echo "$veeamVBRInfoUrl" | jq --raw-output ".buildVersion") 
    veeamDatabaseVendor=$(echo "$veeamVBRInfoUrl" | jq --raw-output ".databaseVendor" | awk '{gsub(/([ ,])/,"\\\\&");print}') 

    #echo "veeam_vbr_info,veeamVBRId=$veeamVBRId,veeamVBRName=$veeamVBRName,veeamVBRVersion=$veeamVBRVersion,veeamDatabaseVendor=$veeamDatabaseVendor vbr=1"

    ##Comment the influx write while debugging
    echo "Writing veeam_vbr_info to InfluxDB"
    influx write \
    -t "$veeamInfluxDBToken" \
    -b "$veeamInfluxDBBucket" \
    -o "$veeamInfluxDBOrg" \
    -p s \
    "veeam_vbr_info,veeamVBRId=$veeamVBRId,veeamVBRName=$veeamVBRName,veeamVBRVersion=$veeamVBRVersion,veeamVBR=$veeamBackupServer,veeamDatabaseVendor=$veeamDatabaseVendor vbr=1"

##
# Veeam Backup & Replication Sessions. This part will check VBR Sessions
##
veeamVBRURL="https://$veeamBackupServer:$veeamBackupPort/api/v1/sessions"
veeamVBRSessionsUrl=$(curl -X GET $veeamVBRURL \
  -H "Authorization: Bearer $veeamBearer" \
  -H  "accept: application/json" \
  -H  "x-api-version: $veeamAPIVersion" \
  2>&1 -k --silent)

declare -i arrayjobsessions=0
if [[ "$veeamVBRSessionsUrl" == "[]" ]]; then
    echo "There are not new veeam_vbr_sessions since $timestart"
else
    for id in $(echo "$veeamVBRSessionsUrl" | jq -r '.data[].id'); do
        veeamVBRSessionJobName=$(echo "$veeamVBRSessionsUrl" | jq --raw-output ".data[$arrayjobsessions].name" | awk '{gsub(/([ ,])/,"\\\\&");print}') 
        veeamVBRSessiontype=$(echo "$veeamVBRSessionsUrl" | jq --raw-output ".data[$arrayjobsessions].sessionType") 
        veeamVBRSessionsJobState=$(echo "$veeamVBRSessionsUrl" | jq --raw-output ".data[$arrayjobsessions].state")
        veeamVBRSessionsJobResult=$(echo "$veeamVBRSessionsUrl" | jq --raw-output ".data[$arrayjobsessions].result.result")     
        case $veeamVBRSessionsJobResult in
            Success)
                jobStatus="1"
            ;;
            Warning)
                jobStatus="2"
            ;;
            Failed)
                jobStatus="3"
            ;;
            esac
        veeamVBRSessionsJobResultMessage=$(echo "$veeamVBRSessionsUrl" | jq --raw-output ".data[$arrayjobsessions].result.message" | awk -F"." 'NR==1{print $1}' | awk '{gsub(/([ ,])/,"\\\\&");print}')
        [[ ! -z "$veeamVBRSessionsJobResultMessage" ]] || veeamVBRSessionsJobResultMessage="None"
        veeamVBRSessionCreationTime=$(echo "$veeamVBRSessionsUrl" | jq --raw-output ".data[$arrayjobsessions].creationTime")
        creationTimeUnix=$(date -d "$veeamVBRSessionCreationTime" +"%s")
        veeamVBRSessionEndTime=$(echo "$veeamVBRSessionsUrl" | jq --raw-output ".data[$arrayjobsessions].endTime")
        endTimeUnix=$(date -d "$veeamVBRSessionEndTime" +"%s")
        veeamBackupSessionsTimeDuration=$(($endTimeUnix-$creationTimeUnix))

        #echo "veeam_vbr_sessions,veeamVBRSessionJobName=$veeamVBRSessionJobName,veeamVBR=$veeamBackupServer,veeamVBRSessiontype=$veeamVBRSessiontype,veeamVBRSessionsJobState=$veeamVBRSessionsJobState,veeamVBRSessionsJobResultMessage=$veeamVBRSessionsJobResultMessage veeamVBRSessionsJobResult=$jobStatus,veeamBackupSessionsTimeDuration=$veeamBackupSessionsTimeDuration $endTimeUnix"
        
        ##Comment the influx write while debugging
        echo "Writing veeam_vbr_sessions to InfluxDB"
        influx write \
        -t "$veeamInfluxDBToken" \
        -b "$veeamInfluxDBBucket" \
        -o "$veeamInfluxDBOrg" \
        -p s \
        "veeam_vbr_sessions,veeamVBR=$veeamBackupServer,veeamVBRSessionJobName=$veeamVBRSessionJobName,veeamVBRSessiontype=$veeamVBRSessiontype,veeamVBRSessionsJobState=$veeamVBRSessionsJobState,veeamVBRSessionsJobResultMessage=$veeamVBRSessionsJobResultMessage veeamVBRSessionsJobResult=$jobStatus,veeamBackupSessionsTimeDuration=$veeamBackupSessionsTimeDuration $endTimeUnix"
        
        if [[ $arrayjobsessions = $veeamJobSessions ]]; then
            break
            else
                arrayjobsessions=$arrayjobsessions+1
        fi
    done
fi

##
# Veeam Backup & Replication Managed Servers. This part will check VBR Managed Servers. Combine this with telegraf agent for beautiful CPU/RAM consumption
##
veeamVBRURL="https://$veeamBackupServer:$veeamBackupPort/api/v1/backupInfrastructure/managedServers"
veeamVBRManagedServersUrl=$(curl -X GET $veeamVBRURL \
  -H "Authorization: Bearer $veeamBearer" \
  -H  "accept: application/json" \
  -H  "x-api-version: $veeamAPIVersion" \
  2>&1 -k --silent)

declare -i arraymanagedservers=0
if [[ "$veeamVBRManagedServersUrl" == "[]" ]]; then
    echo "There are not managed servers "
else
    for id in $(echo "$veeamVBRManagedServersUrl" | jq -r '.data[].id'); do
        veeamVBRMSName=$(echo "$veeamVBRManagedServersUrl" | jq --raw-output ".data[$arraymanagedservers].name" | awk '{gsub(/([ ,])/,"\\\\&");print}') 
        veeamVBRMStype=$(echo "$veeamVBRManagedServersUrl" | jq --raw-output ".data[$arraymanagedservers].type") 
        veeamVBRMSDescription=$(echo "$veeamVBRManagedServersUrl" | jq --raw-output ".data[$arraymanagedservers].description" | awk '{gsub(/([ ,])/,"\\\\&");print}')
        [[ ! -z "$veeamVBRMSDescription" ]] || veeamVBRMSDescription="None"

        #echo "veeam_vbr_managedservers,veeamVBRMSName=$veeamVBRMSName,veeamVBRMStype=$veeamVBRMStype,veeamVBRMSDescription=$veeamVBRMSDescription veeamVBRMSInternalID=$arraymanagedservers"

        ##Comment the influx write while debugging
        echo "Writing veeam_vbr_managedservers to InfluxDB"
        influx write \
        -t "$veeamInfluxDBToken" \
        -b "$veeamInfluxDBBucket" \
        -o "$veeamInfluxDBOrg" \
        -p s \
        "veeam_vbr_managedservers,veeamVBR=$veeamBackupServer,veeamVBRMSName=$veeamVBRMSName,veeamVBRMStype=$veeamVBRMStype,veeamVBRMSDescription=$veeamVBRMSDescription veeamVBRMSInternalID=$arraymanagedservers"

        arraymanagedservers=$arraymanagedservers+1
        
    done
fi

##
# Veeam Backup & Replication Repositories. This part will check VBR Repositories
##
veeamVBRURL="https://$veeamBackupServer:$veeamBackupPort/api/v1/backupInfrastructure/repositories"
veeamVBRRepositoriesUrl=$(curl -X GET $veeamVBRURL \
  -H "Authorization: Bearer $veeamBearer" \
  -H  "accept: application/json" \
  -H  "x-api-version: $veeamAPIVersion" \
  2>&1 -k --silent)

if [[ "$veeamVBRRepositoriesUrl" == "[]" ]]; then
    echo "There are no repositories"
else
    for id in $(echo "$veeamVBRRepositoriesUrl" | jq -r '.data[].id'); do
        veeamVBRRepoName=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").name" | awk '{gsub(/([ ,])/,"\\\\&");print}') 
        veeamVBRRepotype=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").type") 
        veeamVBRRepoDescription=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").description" | awk '{gsub(/([ ,])/,"\\\\&");print}')
        # Fetch and calculate the capacity, free space, and used space
        veeamVBRRepoStateUrl=$(curl -X GET "https://$veeamBackupServer:$veeamBackupPort/api/v1/backupInfrastructure/repositories/states?idFilter=$id" \
            -H "Authorization: Bearer $veeamBearer" \
            -H "accept: application/json" \
            -H "x-api-version: $veeamAPIVersion" \
            2>&1 -k --silent)

            veeamVBRRepoCapacity=$(echo "$veeamVBRRepoStateUrl" | jq --raw-output ".data[] | select(.id==\"$id\").capacityGB" | awk '{printf "%.0f\n", $1 * 1024 * 1024 * 1024}') 
            veeamVBRRepoFree=$(echo "$veeamVBRRepoStateUrl" | jq --raw-output ".data[] | select(.id==\"$id\").freeGB" | awk '{printf "%.0f\n", $1 * 1024 * 1024 * 1024}')
            veeamVBRRepoUsed=$(echo "$veeamVBRRepoStateUrl" | jq --raw-output ".data[] | select(.id==\"$id\").usedSpaceGB" | awk '{printf "%.0f\n", $1 * 1024 * 1024 * 1024}')

            # Let's add some checks and put things to 0 or None if empty or issues        
            [[ ! -z "$veeamVBRRepoDescription" ]] || veeamVBRRepoDescription="None"
            [[ -z "$veeamVBRRepoCapacity" ]] && veeamVBRRepoCapacity=0
            [[ -z "$veeamVBRRepoFree" ]] && veeamVBRRepoFree=0
            [[ -z "$veeamVBRRepoUsed" ]] && veeamVBRRepoUsed=0
        
        case "$veeamVBRRepotype" in
                "WinLocal")
                    veeamVBRRepopath=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").repository.path" | awk '{gsub(/([ ,])/,"\\\\&");print}')
                    veeamVBRRepoPerVM=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").repository.advancedSettings.perVmBackup") 
                    veeamVBRRepoMaxtasks=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").repository.maxTaskCount")
                    influxData="veeam_vbr_repositories,veeamVBR=$veeamBackupServer,veeamVBRRepoName=$veeamVBRRepoName,veeamVBRRepotype=$veeamVBRRepotype,veeamVBRMSDescription=$veeamVBRRepoDescription,veeamVBRRepopath=$veeamVBRRepopath,veeamVBRRepoPerVM=$veeamVBRRepoPerVM veeamVBRRepoMaxtasks=$veeamVBRRepoMaxtasks,veeamVBRRepoCapacity=$veeamVBRRepoCapacity,veeamVBRRepoFree=$veeamVBRRepoFree,veeamVBRRepoUsed=$veeamVBRRepoUsed"
                    #echo $influxData 
                    

                    ##Comment the influx write while debugging
                    echo "Writing veeam_vbr_repositories to InfluxDB"
                    influx write \
                    -t "$veeamInfluxDBToken" \
                    -b "$veeamInfluxDBBucket" \
                    -o "$veeamInfluxDBOrg" \
                    -p s \
                    "$influxData"
                    
                    ;;
                "S3Compatible"|"WasabiCloud")
                    veeamVBRRepoServicePoint=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").account.servicePoint" | awk '{gsub(/([ ,])/,"\\\\&");print}') 
                    veeamVBRRepoRegion=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").account.regionId" | awk '{gsub(/([ ,])/,"\\\\&");print}') 
                    veeamVBRRepoBucketName=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").bucket.bucketName" | awk '{gsub(/([ ,])/,"\\\\&");print}') 
                    veeamVBRRepoBucketFolder=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").bucket.folderName" | awk '{gsub(/([ ,])/,"\\\\&");print}') 
                    veeamVBRRepoBucketImmutable=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").bucket.immutability.isEnabled")
                    veeamVBRRepoBucketImmutableDays=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").bucket.immutability.daysCount")
                    veeamVBRRepoMaxtasks=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").maxTaskCount")
                    influxData="veeam_vbr_repositories,veeamVBR=$veeamBackupServer,veeamVBRRepoName=$veeamVBRRepoName,veeamVBRRepotype=$veeamVBRRepotype,veeamVBRMSDescription=$veeamVBRRepoDescription,veeamVBRRepoServicePoint=$veeamVBRRepoServicePoint,veeamVBRRepoRegion=$veeamVBRRepoRegion,veeamVBRRepoBucketName=$veeamVBRRepoBucketName,veeamVBRRepoBucketFolder=$veeamVBRRepoBucketFolder,veeamVBRRepoBucketImmutable=$veeamVBRRepoBucketImmutable veeamVBRRepoMaxtasks=$veeamVBRRepoMaxtasks,veeamVBRRepoBucketImmutableDays=$veeamVBRRepoBucketImmutableDays,veeamVBRRepoCapacity=$veeamVBRRepoCapacity,veeamVBRRepoFree=$veeamVBRRepoFree,veeamVBRRepoUsed=$veeamVBRRepoUsed"
                    #echo $influxData

                    ##Comment the influx write while debugging
                    echo "Writing veeam_vbr_repositories to InfluxDB"
                    influx write \
                    -t "$veeamInfluxDBToken" \
                    -b "$veeamInfluxDBBucket" \
                    -o "$veeamInfluxDBOrg" \
                    -p s \
                    "$influxData"

                    ;;
                "LinuxHardened")
                    veeamVBRRepopath=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").repository.path" | awk '{gsub(/([ ,])/,"\\\\&");print}') 
                    veeamVBRRepoXFS=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").repository.useFastCloningOnXFSVolumes")
                    veeamVBRRepoBucketImmutableDays=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").repository.makeRecentBackupsImmutableDays")
                    veeamVBRRepoPerVM=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").repository.advancedSettings.perVmBackup")
                    veeamVBRRepoMaxtasks=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").repository.maxTaskCount")
                    influxData="veeam_vbr_repositories,veeamVBR=$veeamBackupServer,veeamVBRRepoName=$veeamVBRRepoName,veeamVBRRepotype=$veeamVBRRepotype,veeamVBRMSDescription=$veeamVBRRepoDescription,veeamVBRRepopath=$veeamVBRRepopath,veeamVBRRepoXFS=$veeamVBRRepoXFS,veeamVBRRepoPerVM=$veeamVBRRepoPerVM veeamVBRRepoMaxtasks=$veeamVBRRepoMaxtasks,veeamVBRRepoBucketImmutableDays=$veeamVBRRepoBucketImmutableDays,veeamVBRRepoCapacity=$veeamVBRRepoCapacity,veeamVBRRepoFree=$veeamVBRRepoFree,veeamVBRRepoUsed=$veeamVBRRepoUsed"
                    #echo $influxData

                    ##Comment the influx write while debugging
                    echo "Writing veeam_vbr_repositories to InfluxDB"
                    influx write \
                    -t "$veeamInfluxDBToken" \
                    -b "$veeamInfluxDBBucket" \
                    -o "$veeamInfluxDBOrg" \
                    -p s \
                    "$influxData"

                    ;;
                "Nfs")
                    veeamVBRRepopath=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").share.sharePath")
                    veeamVBRRepopath=$(echo "$veeamVBRRepopath" | awk '{gsub(/([ ,=])/,"\\\\&");print}')
                    veeamVBRRepoPerVM=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").repository.advancedSettings.perVmBackup")
                    veeamVBRRepoMaxtasks=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").repository.maxTaskCount")
                    influxData="veeam_vbr_repositories,veeamVBR=$veeamBackupServer,veeamVBRRepoName=$veeamVBRRepoName,veeamVBRRepotype=$veeamVBRRepotype,veeamVBRMSDescription=$veeamVBRRepoDescription,veeamVBRRepopath=$veeamVBRRepopath,veeamVBRRepoPerVM=$veeamVBRRepoPerVM veeamVBRRepoMaxtasks=$veeamVBRRepoMaxtasks,veeamVBRRepoCapacity=$veeamVBRRepoCapacity,veeamVBRRepoFree=$veeamVBRRepoFree,veeamVBRRepoUsed=$veeamVBRRepoUsed"
                    #echo $influxData

                    ##Comment the influx write while debugging
                    echo "Writing veeam_vbr_repositories to InfluxDB"
                    influx write \
                    -t "$veeamInfluxDBToken" \
                    -b "$veeamInfluxDBBucket" \
                    -o "$veeamInfluxDBOrg" \
                    -p s \
                    "$influxData"

                    ;;
                "Smb")
                    veeamVBRRepopath=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").share.sharePath")
                    veeamVBRRepopath=$(echo "$veeamVBRRepopath" | sed 's/\\\\/\\/g' | awk '{gsub(/([ ,=])/,"\\\\&");print}')
                    veeamVBRRepoPerVM=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").repository.advancedSettings.perVmBackup")
                    veeamVBRRepoMaxtasks=$(echo "$veeamVBRRepositoriesUrl" | jq --raw-output ".data[] | select(.id==\"$id\").repository.maxTaskCount")
                    influxData="veeam_vbr_repositories,veeamVBR=$veeamBackupServer,veeamVBRRepoName=$veeamVBRRepoName,veeamVBRRepotype=$veeamVBRRepotype,veeamVBRMSDescription=$veeamVBRRepoDescription,veeamVBRRepopath=$veeamVBRRepopath,veeamVBRRepoPerVM=$veeamVBRRepoPerVM veeamVBRRepoMaxtasks=$veeamVBRRepoMaxtasks,veeamVBRRepoCapacity=$veeamVBRRepoCapacity,veeamVBRRepoFree=$veeamVBRRepoFree,veeamVBRRepoUsed=$veeamVBRRepoUsed"
                    #echo $influxData

                    ##Comment the influx write while debugging
                    echo "Writing veeam_vbr_repositories to InfluxDB"
                    influx write \
                    -t "$veeamInfluxDBToken" \
                    -b "$veeamInfluxDBBucket" \
                    -o "$veeamInfluxDBOrg" \
                    -p s \
                    "$influxData"

                    ;;
                *)
                    echo "Unknown repository type: $veeamVBRRepoType"
                    ;;
        esac

    done
fi


##
# Veeam Backup & Replication Proxies. This part will check VBR Proxies
##
veeamVBRURL="https://$veeamBackupServer:$veeamBackupPort/api/v1/backupInfrastructure/proxies"
veeamVBRProxiesUrl=$(curl -X GET $veeamVBRURL \
  -H "Authorization: Bearer $veeamBearer" \
  -H  "accept: application/json" \
  -H  "x-api-version: $veeamAPIVersion" \
  2>&1 -k --silent)

declare -i arrayproxies=0
if [[ "$veeamVBRProxiesUrl" == "[]" ]]; then
    echo "There are not Proxies"
else
    for id in $(echo "$veeamVBRProxiesUrl" | jq -r '.data[].id'); do
        veeamVBRProxyName=$(echo "$veeamVBRProxiesUrl" | jq --raw-output ".data[$arrayproxies].name" | awk '{gsub(/([ ,])/,"\\\\&");print}') 
        veeamVBRProxytype=$(echo "$veeamVBRProxiesUrl" | jq --raw-output ".data[$arrayproxies].type") 
        veeamVBRProxyDescription=$(echo "$veeamVBRProxiesUrl" | jq --raw-output ".data[$arrayproxies].description" | awk '{gsub(/([ ,])/,"\\\\&");print}')
        [[ ! -z "$veeamVBRProxyDescription" ]] || veeamVBRProxyDescription="None"
        veeamVBRProxyMode=$(echo "$veeamVBRProxiesUrl" | jq --raw-output ".data[$arrayproxies].server.transportMode")
        veeamVBRProxyTask=$(echo "$veeamVBRProxiesUrl" | jq --raw-output ".data[$arrayproxies].server.maxTaskCount")

        #echo "veeam_vbr_proxies,veeamVBRProxyName=$veeamVBRProxyName,veeamVBRProxytype=$veeamVBRProxytype,veeamVBRProxyDescription=$veeamVBRProxyDescription,veeamVBRProxyMode=$veeamVBRProxyMode veeamVBRProxyTask=$veeamVBRProxyTask"

        ##Comment the influx write while debugging
        echo "Writing veeam_vbr_proxies to InfluxDB"
        influx write \
        -t "$veeamInfluxDBToken" \
        -b "$veeamInfluxDBBucket" \
        -o "$veeamInfluxDBOrg" \
        -p s \
        "veeam_vbr_proxies,veeamVBR=$veeamBackupServer,veeamVBRProxyName=$veeamVBRProxyName,veeamVBRProxytype=$veeamVBRProxytype,veeamVBRProxyDescription=$veeamVBRProxyDescription,veeamVBRProxyMode=$veeamVBRProxyMode veeamVBRProxyTask=$veeamVBRProxyTask"


    arrayproxies+=1
        
    done
fi

##
# Veeam Backup & Replication Backup Objects. This part will check VBR Backup Objects
##
veeamVBRURL="https://$veeamBackupServer:$veeamBackupPort/api/v1/backupObjects"
veeamVBRBObjectsUrl=$(curl -X GET $veeamVBRURL \
  -H "Authorization: Bearer $veeamBearer" \
  -H  "accept: application/json" \
  -H  "x-api-version: $veeamAPIVersion" \
  2>&1 -k --silent)

declare -i arraybobjects=0
if [[ "$veeamVBRBObjectsUrl" == "[]" ]]; then
    echo "There are not Proxies"
else
    for id in $(echo "$veeamVBRBObjectsUrl" | jq -r '.data[].id'); do
        veeamVBRBobjectName=$(echo "$veeamVBRBObjectsUrl" | jq --raw-output ".data[$arraybobjects].name" | awk '{gsub(/([ ,])/,"\\\\&");print}') 
        veeamVBRBobjecttype=$(echo "$veeamVBRBObjectsUrl" | jq --raw-output ".data[$arraybobjects].type") 
        veeamVBRBobjectPlatform=$(echo "$veeamVBRBObjectsUrl" | jq --raw-output ".data[$arraybobjects].platformName")
        veeamVBRBobjectviType=$(echo "$veeamVBRBObjectsUrl" | jq --raw-output ".data[$arraybobjects].viType")
        veeamVBRBobjectObjectId=$(echo "$veeamVBRBObjectsUrl" | jq --raw-output ".data[$arraybobjects].objectId")
        veeamVBRBobjectPath=$(echo "$veeamVBRBObjectsUrl" | jq --raw-output ".data[$arraybobjects].path" | awk '{gsub(/([ ,\n])/,"\\\\&");print}')
        [[ ! -z "$veeamVBRBobjectPath" ]] || veeamVBRBobjectPath="None"
        veeamVBRBobjectrp=$(echo "$veeamVBRBObjectsUrl" | jq --raw-output ".data[$arraybobjects].restorePointsCount")

        #echo "veeam_vbr_backupobjects,veeamVBRBobjectName=$veeamVBRBobjectName,veeamVBRBobjecttype=$veeamVBRBobjecttype,veeamVBRBobjectPlatform=$veeamVBRBobjectPlatform,veeamVBRBobjectviType=$veeamVBRBobjectviType,veeamVBRBobjectObjectId=$veeamVBRBobjectObjectId,veeamVBRBobjectPath=$veeamVBRBobjectPath restorePointsCount=$veeamVBRBobjectrp"

        ##Comment the influx write while debugging
        echo "Writing veeam_vbr_backupobjects to InfluxDB"
        influx write \
        -t "$veeamInfluxDBToken" \
        -b "$veeamInfluxDBBucket" \
        -o "$veeamInfluxDBOrg" \
        -p s \
        "veeam_vbr_backupobjects,veeamVBR=$veeamBackupServer,veeamVBRBobjectName=$veeamVBRBobjectName,veeamVBRBobjecttype=$veeamVBRBobjecttype,veeamVBRBobjectPlatform=$veeamVBRBobjectPlatform,veeamVBRBobjectviType=$veeamVBRBobjectviType,veeamVBRBobjectObjectId=$veeamVBRBobjectObjectId,veeamVBRBobjectPath=$veeamVBRBobjectPath restorePointsCount=$veeamVBRBobjectrp"

    arraybobjects+=1
        
    done
fi