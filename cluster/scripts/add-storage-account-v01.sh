#! /bin/bash
CORESITEPATH=/etc/hadoop/conf/core-site.xml
AMBARICONFIGS_SH=/var/lib/ambari-server/resources/scripts/configs.sh
PORT=8080
ACTIVEAMBARIHOST=headnodehost

usage() {
  echo ""
  echo "Usage: sudo -E bash add-storage-account-v01.sh";
  echo "This script does NOT require Ambari username and password";
  exit 132;
}
        
checkHostNameAndSetClusterName() {
  fullHostName=$(hostname -f)
  echo "fullHostName=$fullHostName"
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

validateUsernameAndPassword() {
  coreSiteContent=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD get $ACTIVEAMBARIHOST $CLUSTERNAME core-site)
  if [[ $coreSiteContent == *"[ERROR]"* && $coreSiteContent == *"Bad credentials"* ]]; then
     echo "[ERROR] Username and password are invalid. Exiting!"
     exit 134
  fi
}

updateAmbariConfigs() {
  updateResult=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD set $ACTIVEAMBARIHOST $CLUSTERNAME core-site $1 $2)
  if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
    echo "[ERROR] Failed to update core-site. Exiting!"
    echo $updateResult
    exit 135
  fi
  echo "Added $1 = $2"
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

checkHostNameAndSetClusterName
validateUsernameAndPassword

args=("$@")  
for ((i=0; i<${#args[@]}; i+=2)); do
  if [ -z "${args[i]}" ] || [ -z "${args[i+1]}" ] || checkAccountName ${args[i]} || keyIsBase64Encoded ${args[i+1]}; then
    echo "[ERROR] ${args[i]} ${args[i+1]} "
  else    
    updateAmbariConfigs fs.azure.account.key.${args[i]}.blob.core.windows.net ${args[i+1]}
  fi
done

stopServiceViaRest HDFS
stopServiceViaRest YARN
stopServiceViaRest MAPREDUCE2
stopServiceViaRest OOZIE

startServiceViaRest YARN
startServiceViaRest MAPREDUCE2
startServiceViaRest OOZIE
startServiceViaRest HDFS
