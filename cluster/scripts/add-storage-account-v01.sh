#! /bin/bash
CORESITEPATH=/etc/hadoop/conf/core-site.xml
AMBARICONFIGS_SH=/var/lib/ambari-server/resources/scripts/configs.sh
PORT=8080
ACTIVEAMBARIHOST=headnodehost

usage() {
  echo ""
  echo "Usage: sudo -E bash add-storage-account-v01.sh";
  echo "If -p option is specified, then storage account key will be stored in plain text. Otherwise, it will be encrypted."
  echo "This script does NOT require Ambari username and password";
  exit 132;
}
wget -O /tmp/HDInsightUtilities-v01.sh -q https://hdiconfigactions.blob.core.windows.net/linuxconfigactionmodulev01/HDInsightUtilities-v01.sh && source /tmp/HDInsightUtilities-v01.sh && rm -f /tmp/HDInsightUtilities-v01.sh

checkHostNameAndSetClusterName() {
  PRIMARYHEADNODE=`get_primary_headnode`
    
  #Check if values retrieved are empty, if yes, exit with error
  if [[ -z $PRIMARYHEADNODE ]]; then
  echo "Could not determine primary headnode."
  exit 139
  fi

  fullHostName=$(hostname -f)
    echo "fullHostName=$fullHostName. Lower case: ${fullHostName,,}"
    echo "primary headnode=$PRIMARYHEADNODE. Lower case: ${PRIMARYHEADNODE,,}"
    if [ "${fullHostName,,}" != "${PRIMARYHEADNODE,,}" ]; then
        echo "$fullHostName is not primary headnode. This script has to be run on $PRIMARYHEADNODE."
        exit 0
    fi
    CLUSTERNAME=$(sed -n -e 's/.*\.\(.*\)-ssh.*/\1/p' <<< $fullHostName)
    if [ -z "$CLUSTERNAME" ]; then
        CLUSTERNAME=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nprint ClusterManifestParser.parse_local_manifest().deployment.cluster_name" | python)
        if [ $? -ne 0 ]; then
            echo "[ERROR] Cannot determine cluster name. Exiting!"
            exit 133
        fi
    fi
    echo "Cluster Name=$CLUSTERNAME"
}

checkHostNameAndSetClusterName

validateUsernameAndPassword() {
  coreSiteContent=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD get $ACTIVEAMBARIHOST $CLUSTERNAME core-site)
  if [[ $coreSiteContent == *"[ERROR]"* && $coreSiteContent == *"Bad credentials"* ]]; then
     echo "[ERROR] Username and password are invalid. Exiting!"
     exit 134
  fi
}

updateAmbariConfigs() {
  STORAGEACCOUNTNAME=$1
  if [ "$DISABLEENCRYPTION" == true ]; then
    echo "Encryption is disabled. No changes will be made to storage account key."
  else
    echo "Encrypting storage account key"
    echo "Getting encryption cert"
    for cert in `sudo ls /var/lib/waagent/*.crt`
    do
      SUBJECT=`sudo openssl x509 -in $cert -noout -subject`
      if [[ $SUBJECT == *"cluster-$CLUSTERNAME-"* ]]; then
          CERT=$cert
          break
      fi
    done

    if [ -z "$CERT" ];then
      echo "Could not locate cert for encryption"
      exit 142
    fi

    echo $2 | sudo openssl cms -encrypt -outform PEM -out storagekey.txt $CERT
    if (( $? )); then
      echo "Could not encrypt storage account key"
      exit 140
    fi

    STORAGEACCOUNTKEY=$(echo -e "import re\n\nfile = open('storagekey.txt', 'r')\nfor line in file.read().splitlines():\n\tif '-----BEGIN CMS-----' in line or '-----END CMS-----' in line:\n\t\tcontinue\n\telse:\n\t\tprint line\nfile.close()" | sudo python)
    STORAGEACCOUNTKEY=$(echo $STORAGEACCOUNTKEY | tr -d ' ')
    if [ -z "$STORAGEACCOUNTKEY" ];
    then
      echo "Storage account key could not be stripped off header values form encrypted key"
      exit 141
    fi
    rm storagekey.txt
  fi 


  updateResult=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD set $ACTIVEAMBARIHOST $CLUSTERNAME core-site "fs.azure.account.key.$STORAGEACCOUNTNAME.blob.core.windows.net" "$STORAGEACCOUNTKEY")
    
    if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
        echo "[ERROR] Failed to update core-site. Exiting!"
        echo $updateResult
        exit 135
    fi
    echo "Added property: 'fs.azure.account.key.$STORAGEACCOUNTNAME.blob.core.windows.net' with storage account key"

	updateResult=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD set $ACTIVEAMBARIHOST $CLUSTERNAME core-site "fs.azure.account.keyprovider.$STORAGEACCOUNTNAME.blob.core.windows.net" "org.apache.hadoop.fs.azure.$KEYPROVIDER")    
	if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
		echo "[ERROR] Failed to update core-site. Exiting!"
		echo $updateResult
		exit 135
	fi
	echo "Added property: 'fs.azure.account.keyprovider.$STORAGEACCOUNTNAME.blob.core.windows.net':org.apache.hadoop.fs.azure.$KEYPROVIDER "

}

stopServiceViaRest() {
  if [ -z "$1" ]; then
    echo "Need service name to stop service"
    exit 136
  fi
  SERVICENAME=$1
  echo "Stopping $SERVICENAME"
  curl -u $USERID:$PASSWD -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Stop Service for Hue installation"}, "Body": {"ServiceInfo": {"state": "INSTALLED"}}}' http://$ACTIVEAMBARIHOST:$PORT/api/v1/clusters/$CLUSTERNAME/services/$SERVICENAME
}

startServiceViaRest() {
  if [ -z "$1" ]; then
    echo "Need service name to start service"
    exit 136
  fi
  sleep 2
  SERVICENAME=$1
  echo "Starting $SERVICENAME"
  startResult=$(curl -u $USERID:$PASSWD -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Start Service for Hue installation"}, "Body": {"ServiceInfo": {"state": "STARTED"}}}' http://$ACTIVEAMBARIHOST:$PORT/api/v1/clusters/$CLUSTERNAME/services/$SERVICENAME)
  if [[ $startResult == *"500 Server Error"* || $startResult == *"internal system exception occurred"* ]]; then
    sleep 60
    echo "Retry starting $SERVICENAME"
    startResult=$(curl -u $USERID:$PASSWD -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Start Service for Hue installation"}, "Body": {"ServiceInfo": {"state": "STARTED"}}}' http://$ACTIVEAMBARIHOST:$PORT/api/v1/clusters/$CLUSTERNAME/services/$SERVICENAME)
  fi
  echo $startResult
}

checkAccountName() {
 if [[ $1 =~ [a-z0-9]{3,24} ]]; then
   return 1
 else
   return 0  
 fi
}

keyIsBase64Encoded(){
  if [[ $1 =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{4}|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)$ ]]; then
    return 1
  else
    return 0
  fi
}

#############
if [ "$(id -u)" != "0" ]; then
  echo "[ERROR] The script has to be run as root."
  usage
fi

USERID=$(echo -e "import hdinsight_common.Constants as Constants\nprint Constants.AMBARI_WATCHDOG_USERNAME" | python)

echo "USERID=$USERID"

PASSWD=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nimport hdinsight_common.Constants as Constants\nimport base64\nbase64pwd = ClusterManifestParser.parse_local_manifest().ambari_users.usersmap[Constants.AMBARI_WATCHDOG_USERNAME].password\nprint base64.b64decode(base64pwd)" | python)

validateUsernameAndPassword

args=("$@")
ARG_LEN=${#args[@]}
if [ "${args[$ARG_LEN-1]}" == "-p" ]
  then
    DISABLEENCRYPTION=true
    KEYPROVIDER=SimpleKeyProvider
    ARG_LEN=$(( ARG_LEN - 1 ))
    echo "Key encryption is disabled."
  else
    DISABLEENCRYPTION=false
    KEYPROVIDER=ShellDecryptionKeyProvider
    echo "Key encryption is enabled"
fi


for ((i=0; i<$ARG_LEN; i+=2)); do
  if [ -z "${args[i]}" ] || [ -z "${args[i+1]}" ] || checkAccountName ${args[i]} || keyIsBase64Encoded ${args[i+1]}; then
    echo "[ERROR] ${args[i]} ${args[i+1]} "
  else
    updateAmbariConfigs ${args[i]} ${args[i+1]}
  fi
done

if (( $ARG_LEN>1 )); then
  stopServiceViaRest OOZIE
  stopServiceViaRest YARN
  stopServiceViaRest MAPREDUCE2
  stopServiceViaRest HDFS
  stopServiceViaRest HIVE

  #sleep for 30 seconds to reduce the possibility of race condition in stopping and starting services
  sleep 30

  startServiceViaRest HIVE
  startServiceViaRest HDFS
  startServiceViaRest MAPREDUCE2
  startServiceViaRest YARN
  startServiceViaRest OOZIE
fi
