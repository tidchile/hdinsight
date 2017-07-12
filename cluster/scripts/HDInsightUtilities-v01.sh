function download_file
{
    srcurl=$1;
    destfile=$2;
    overwrite=$3;

    if [ "$overwrite" = false ] && [ -e $destfile ]; then
        return;
    fi

    wget -O $destfile -q $srcurl;
}

function untar_file
{
    zippedfile=$1;
    unzipdir=$2;

    if [ -e $zippedfile ]; then
        tar -xf $zippedfile -C $unzipdir;
    fi
}

function test_is_headnode
{
    shorthostname=`hostname -s`
    if [[  $shorthostname == headnode* || $shorthostname == hn* ]]; then
        echo 1;
    else
        echo 0;
    fi
}

function test_is_datanode
{
    shorthostname=`hostname -s`
    if [[ $shorthostname == workernode* || $shorthostname == wn* ]]; then
        echo 1;
    else
        echo 0;
    fi
}

function test_is_zookeepernode
{
    shorthostname=`hostname -s`
    if [[ $shorthostname == zookeepernode* || $shorthostname == zk* ]]; then
        echo 1;
    else
        echo 0;
    fi
}

function test_is_first_datanode
{
    shorthostname=`hostname -s`
    if [[ $shorthostname == workernode0 || $shorthostname == wn0-* ]]; then
        echo 1;
    else
        echo 0;
    fi
}

#following functions are used to determine headnodes. 
#Returns fully qualified headnode names separated by comma by inspecting hdfs-site.xml.
#Returns empty string in case of errors.
function get_headnodes
{
    hdfssitepath=/etc/hadoop/conf/hdfs-site.xml
    nn1=$(sed -n '/<name>dfs.namenode.http-address.mycluster.nn1/,/<\/value>/p' $hdfssitepath)
    nn2=$(sed -n '/<name>dfs.namenode.http-address.mycluster.nn2/,/<\/value>/p' $hdfssitepath)

    nn1host=$(sed -n -e 's/.*<value>\(.*\)<\/value>.*/\1/p' <<< $nn1 | cut -d ':' -f 1)
    nn2host=$(sed -n -e 's/.*<value>\(.*\)<\/value>.*/\1/p' <<< $nn2 | cut -d ':' -f 1)

    nn1hostnumber=$(sed -n -e 's/hn\(.*\)-.*/\1/p' <<< $nn1host)
    nn2hostnumber=$(sed -n -e 's/hn\(.*\)-.*/\1/p' <<< $nn2host)

    #only if both headnode hostnames could be retrieved, hostnames will be returned
    #else nothing is returned
    if [[ ! -z $nn1host && ! -z $nn2host ]]
    then
        if (( $nn1hostnumber < $nn2hostnumber )); then
                        echo "$nn1host,$nn2host"
        else
                        echo "$nn2host,$nn1host"
        fi
    fi
}

function get_primary_headnode
{
        headnodes=`get_headnodes`
        echo "`(echo $headnodes | cut -d ',' -f 1)`"
}

function get_secondary_headnode
{
        headnodes=`get_headnodes`
        echo "`(echo $headnodes | cut -d ',' -f 2)`"
}

function get_primary_headnode_number
{
        primaryhn=`get_primary_headnode`
        echo "`(sed -n -e 's/hn\(.*\)-.*/\1/p' <<< $primaryhn)`"
}

function get_secondary_headnode_number
{
        secondaryhn=`get_secondary_headnode`
        echo "`(sed -n -e 's/hn\(.*\)-.*/\1/p' <<< $secondaryhn)`"
}
