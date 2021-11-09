 #!/bin/bash
# Copyright (c) 2021 Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

# Fail on error
set -e


# Create Object Store Bucket (Should be replaced by terraform one day)
while ! state_done OBJECT_STORE_BUCKET; do
  oci os bucket create --compartment-id "$(state_get COMPARTMENT_OCID)" --name "$(state_get RUN_NAME)"
  state_set_done OBJECT_STORE_BUCKET
done


# Wait for DATABASE1 DB OCID
while ! state_done DATABASE1_DB_OCID; do
  echo "`date`: Waiting for DATABASE1_DB_OCID"
  sleep 2
done


# Wait for DATABASE2 DB OCID
while ! state_done DATABASE2_DB_OCID; do
  echo "`date`: Waiting for DATABASE2_DB_OCID"
  sleep 2
done


# Get Wallet
while ! state_done WALLET_GET; do
  cd $GRABDISH_HOME
  mkdir wallet
  cd wallet
  oci db autonomous-database generate-wallet --autonomous-database-id "$(state_get DATABASE1_DB_OCID)" --file 'wallet.zip' --password 'Welcome1' --generate-type 'ALL'
  unzip wallet.zip
  cd $GRABDISH_HOME
  state_set_done WALLET_GET
done


# Get DB Connection Wallet and to Object Store
while ! state_done CWALLET_SSO_OBJECT; do
  cd $GRABDISH_HOME/wallet
  oci os object put --bucket-name "$(state_get RUN_NAME)" --name "cwallet.sso" --file 'cwallet.sso'
  cd $GRABDISH_HOME
  state_set_done CWALLET_SSO_OBJECT
done


# Create Authenticated Link to Wallet
while ! state_done CWALLET_SSO_AUTH_URL; do
  ACCESS_URI=`oci os preauth-request create --object-name 'cwallet.sso' --access-type 'ObjectRead' --bucket-name "$(state_get RUN_NAME)" --name 'grabdish' --time-expires $(date '+%Y-%m-%d' --date '+7 days') --query 'data."access-uri"' --raw-output`
  state_set CWALLET_SSO_AUTH_URL "https://objectstorage.$(state_get REGION).oraclecloud.com${ACCESS_URI}"
done


# Give DB_PASSWORD priority
while ! state_done DB_PASSWORD; do
  echo "Waiting for DB_PASSWORD"
  sleep 5
done


# Create DATABASE2 ATP Bindings
while ! state_done DB_WALLET_SECRET; do
  cd $GRABDISH_HOME/wallet
  cat - >sqlnet.ora <<!
WALLET_LOCATION = (SOURCE = (METHOD = file) (METHOD_DATA = (DIRECTORY="/msdataworkshop/creds")))
SSL_SERVER_DN_MATCH=yes
!
  if kubectl create -f - -n msdataworkshop; then
    state_set_done DB_WALLET_SECRET
  else
    echo "Error: Failure to create db-wallet-secret.  Retrying..."
    sleep 5
  fi <<!
apiVersion: v1
data:
  README: $(base64 -w0 README)
  cwallet.sso: $(base64 -w0 cwallet.sso)
  ewallet.p12: $(base64 -w0 ewallet.p12)
  keystore.jks: $(base64 -w0 keystore.jks)
  ojdbc.properties: $(base64 -w0 ojdbc.properties)
  sqlnet.ora: $(base64 -w0 sqlnet.ora)
  tnsnames.ora: $(base64 -w0 tnsnames.ora)
  truststore.jks: $(base64 -w0 truststore.jks)
kind: Secret
metadata:
  name: db-wallet-secret
!
  cd $GRABDISH_HOME
done


# DB Connection Setup
export TNS_ADMIN=$GRABDISH_HOME/wallet
cat - >$TNS_ADMIN/sqlnet.ora <<!
WALLET_LOCATION = (SOURCE = (METHOD = file) (METHOD_DATA = (DIRECTORY="$TNS_ADMIN")))
SSL_SERVER_DN_MATCH=yes
!
DATABASE1_DB_SVC="$(state_get DATABASE1_DB_NAME)_tp"
DATABASE2_DB_SVC="$(state_get DATABASE2_DB_NAME)_tp"
DATABASE1_USER=DATABASE1USER
DATABASE2_USER=DATABASE2USER
DATABASE1_LINK=DATABASE1TODATABASE2LINK
DATABASE2_LINK=DATABASE2TODATABASE1LINK
DATABASE1_QUEUE=DATABASE1QUEUE
DATABASE2_QUEUE=DATABASE2QUEUE


# Get DB Password
while true; do
  if DB_PASSWORD=`kubectl get secret dbuser -n msdataworkshop --template={{.data.dbpassword}} | base64 --decode`; then
    if ! test -z "$DB_PASSWORD"; then
      break
    fi
  fi
  echo "Error: Failed to get DB password.  Retrying..."
  sleep 5
done


# Wait for DB Password to be set in DATABASE1 DB
while ! state_done DATABASE1_DB_PASSWORD_SET; do
  echo "`date`: Waiting for DATABASE1_DB_PASSWORD_SET"
  sleep 2
done


# DATABASE1 DB User, Objects
while ! state_done DATABASE1_USER; do
  U=$DATABASE1_USER
  SVC=$DATABASE1_DB_SVC
  sqlplus /nolog <<!
WHENEVER SQLERROR EXIT 1
connect admin/"$DB_PASSWORD"@$SVC
CREATE USER $U IDENTIFIED BY "$DB_PASSWORD";
GRANT pdb_dba TO $U;
GRANT EXECUTE ON DBMS_CLOUD_ADMIN TO $U;
GRANT EXECUTE ON DBMS_CLOUD TO $U;
GRANT CREATE DATABASE LINK TO $U;
GRANT unlimited tablespace to $U;
GRANT connect, resource TO $U;
GRANT aq_user_role TO $U;
GRANT EXECUTE ON sys.dbms_aqadm TO $U;
GRANT EXECUTE ON sys.dbms_aq TO $U;

GRANT SODA_APP to $U;

connect $U/"$DB_PASSWORD"@$SVC

BEGIN
DBMS_AQADM.CREATE_QUEUE_TABLE (
queue_table          => 'DATABASE1QUEUETABLE',
queue_payload_type   => 'SYS.AQ\$_JMS_TEXT_MESSAGE',
multiple_consumers   => true,
compatible           => '8.1');

DBMS_AQADM.CREATE_QUEUE (
queue_name          => '$DATABASE1_QUEUE',
queue_table         => 'DATABASE1QUEUETABLE');

DBMS_AQADM.START_QUEUE (
queue_name          => '$DATABASE1_QUEUE');
END;
/

BEGIN
DBMS_AQADM.CREATE_QUEUE_TABLE (
queue_table          => 'DATABASE2QUEUETABLE',
queue_payload_type   => 'SYS.AQ\$_JMS_TEXT_MESSAGE',
compatible           => '8.1');

DBMS_AQADM.CREATE_QUEUE (
queue_name          => '$DATABASE2_QUEUE',
queue_table         => 'DATABASE2QUEUETABLE');

DBMS_AQADM.START_QUEUE (
queue_name          => '$DATABASE2_QUEUE');
END;
/
!
  state_set_done DATABASE1_USER
done


# Wait for DB Password to be set in DATABASE2 DB
while ! state_done DATABASE2_DB_PASSWORD_SET; do
  echo "`date`: Waiting for DATABASE2_DB_PASSWORD_SET"
  sleep 2
done


# DATABASE2 DB User, Objects
while ! state_done DATABASE2_USER; do
  U=$DATABASE2_USER
  SVC=$DATABASE2_DB_SVC
  sqlplus /nolog <<!
WHENEVER SQLERROR EXIT 1
connect admin/"$DB_PASSWORD"@$SVC
CREATE USER $U IDENTIFIED BY "$DB_PASSWORD";
GRANT pdb_dba TO $U;
GRANT EXECUTE ON DBMS_CLOUD_ADMIN TO $U;
GRANT EXECUTE ON DBMS_CLOUD TO $U;
GRANT CREATE DATABASE LINK TO $U;
GRANT unlimited tablespace to $U;
GRANT connect, resource TO $U;
GRANT aq_user_role TO $U;
GRANT EXECUTE ON sys.dbms_aqadm TO $U;
GRANT EXECUTE ON sys.dbms_aq TO $U;

connect $U/"$DB_PASSWORD"@$SVC

BEGIN
DBMS_AQADM.CREATE_QUEUE_TABLE (
queue_table          => 'DATABASE1QUEUETABLE',
queue_payload_type   => 'SYS.AQ\$_JMS_TEXT_MESSAGE',
compatible           => '8.1');

DBMS_AQADM.CREATE_QUEUE (
queue_name          => '$DATABASE1_QUEUE',
queue_table         => 'DATABASE1QUEUETABLE');

DBMS_AQADM.START_QUEUE (
queue_name          => '$DATABASE1_QUEUE');
END;
/

BEGIN
DBMS_AQADM.CREATE_QUEUE_TABLE (
queue_table          => 'DATABASE2QUEUETABLE',
queue_payload_type   => 'SYS.AQ\$_JMS_TEXT_MESSAGE',
multiple_consumers   => true,
compatible           => '8.1');

DBMS_AQADM.CREATE_QUEUE (
queue_name          => '$DATABASE2_QUEUE',
queue_table         => 'DATABASE2QUEUETABLE');

DBMS_AQADM.START_QUEUE (
queue_name          => '$DATABASE2_QUEUE');
END;
/

create table DATABASE2 (
  DATABASE2id varchar(16) PRIMARY KEY NOT NULL,
  DATABASE2location varchar(32),
  DATABASE2count integer CONSTRAINT positive_DATABASE2 CHECK (DATABASE2count >= 0) );

insert into DATABASE2 values ('sushi', '1468 WEBSTER ST,San Francisco,CA', 0);
insert into DATABASE2 values ('pizza', '1469 WEBSTER ST,San Francisco,CA', 0);
insert into DATABASE2 values ('burger', '1470 WEBSTER ST,San Francisco,CA', 0);
commit;
!
  state_set_done DATABASE2_USER
done


# DATABASE1 DB Link
while ! state_done DATABASE1_DB_LINK; do
  U=$DATABASE1_USER
  SVC=$DATABASE1_DB_SVC
  TU=$DATABASE2_USER
  TSVC=$DATABASE2_DB_SVC
  TTNS=`grep -i "^$TSVC " $TNS_ADMIN/tnsnames.ora`
  LINK=$DATABASE1_LINK
  sqlplus /nolog <<!
WHENEVER SQLERROR EXIT 1
connect $U/"$DB_PASSWORD"@$SVC
BEGIN
  DBMS_CLOUD.GET_OBJECT(
    object_uri => '$(state_get CWALLET_SSO_AUTH_URL)',
    directory_name => 'DATA_PUMP_DIR');

  DBMS_CLOUD.CREATE_CREDENTIAL(
    credential_name => 'CRED',
    username => '$TU',
    password => '$DB_PASSWORD');

  DBMS_CLOUD_ADMIN.CREATE_DATABASE_LINK(
    db_link_name => '$LINK',
    hostname => '`grep -oP '(?<=host=).*?(?=\))' <<<"$TTNS"`',
    port => '`grep -oP '(?<=port=).*?(?=\))' <<<"$TTNS"`',
    service_name => '`grep -oP '(?<=service_name=).*?(?=\))' <<<"$TTNS"`',
    ssl_server_cert_dn => '`grep -oP '(?<=ssl_server_cert_dn=\").*?(?=\"\))' <<<"$TTNS"`',
    credential_name => 'CRED',
    directory_name => 'DATA_PUMP_DIR');
END;
/
!
  state_set_done DATABASE1_DB_LINK
done

# DATABASE2 DB Link
while ! state_done DATABASE2_DB_LINK; do
  U=$DATABASE2_USER
  SVC=$DATABASE2_DB_SVC
  TU=$DATABASE1_USER
  TSVC=$DATABASE1_DB_SVC
  TTNS=`grep -i "^$TSVC " $TNS_ADMIN/tnsnames.ora`
  LINK=$DATABASE2_LINK
  sqlplus /nolog <<!
WHENEVER SQLERROR EXIT 1
connect $U/"$DB_PASSWORD"@$SVC
BEGIN
  DBMS_CLOUD.GET_OBJECT(
    object_uri => '$(state_get CWALLET_SSO_AUTH_URL)',
    directory_name => 'DATA_PUMP_DIR');

  DBMS_CLOUD.CREATE_CREDENTIAL(
    credential_name => 'CRED',
    username => '$TU',
    password => '$DB_PASSWORD');

  DBMS_CLOUD_ADMIN.CREATE_DATABASE_LINK(
    db_link_name => '$LINK',
    hostname => '`grep -oP '(?<=host=).*?(?=\))' <<<"$TTNS"`',
    port => '`grep -oP '(?<=port=).*?(?=\))' <<<"$TTNS"`',
    service_name => '`grep -oP '(?<=service_name=).*?(?=\))' <<<"$TTNS"`',
    ssl_server_cert_dn => '`grep -oP '(?<=ssl_server_cert_dn=\").*?(?=\"\))' <<<"$TTNS"`',
    credential_name => 'CRED',
    directory_name => 'DATA_PUMP_DIR');
END;
/
!
  state_set_done DATABASE2_DB_LINK
done


# DATABASE1 Queues and Propagation
while ! state_done DATABASE1_PROPAGATION; do
  U=$DATABASE1_USER
  SVC=$DATABASE1_DB_SVC
  TU=$DATABASE2_USER
  TSVC=$DATABASE2_DB_SVC
  LINK=$DATABASE1_LINK
  Q=$DATABASE1_QUEUE
  sqlplus /nolog <<!
WHENEVER SQLERROR EXIT 1
connect $U/"$DB_PASSWORD"@$SVC
BEGIN
DBMS_AQADM.add_subscriber(
   queue_name=>'$Q',
   subscriber=>sys.aq\$_agent(null,'$TU.$Q@$LINK',0),
   queue_to_queue => true);
END;
/

BEGIN
dbms_aqadm.schedule_propagation
      (queue_name        => '$U.$Q'
      ,destination_queue => '$TU.$Q'
      ,destination       => '$LINK'
      ,start_time        => sysdate --immediately
      ,duration          => null    --until stopped
      ,latency           => 0);     --No gap before propagating
END;
/
!
  state_set_done DATABASE1_PROPAGATION
done


# DATABASE2 Queues and Propagation
while ! state_done DATABASE2_PROPAGATION; do
  U=$DATABASE2_USER
  SVC=$DATABASE2_DB_SVC
  TU=$DATABASE1_USER
  TSVC=$DATABASE1_DB_SVC
  LINK=$DATABASE2_LINK
  Q=$DATABASE2_QUEUE
  sqlplus /nolog <<!
WHENEVER SQLERROR EXIT 1
connect $U/"$DB_PASSWORD"@$SVC
BEGIN
DBMS_AQADM.add_subscriber(
   queue_name=>'$Q',
   subscriber=>sys.aq\$_agent(null,'$TU.$Q@$LINK',0),
   queue_to_queue => true);
END;
/

BEGIN
dbms_aqadm.schedule_propagation
      (queue_name        => '$U.$Q'
      ,destination_queue => '$TU.$Q'
      ,destination       => '$LINK'
      ,start_time        => sysdate --immediately
      ,duration          => null    --until stopped
      ,latency           => 0);     --No gap before propagating
END;
/
!
  state_set_done DATABASE2_PROPAGATION
done


# .net DATABASE2 DB Proc
while ! state_done DOT_NET_DATABASE2_DB_PROC; do
  U=$DATABASE2_USER
  SVC=$DATABASE2_DB_SVC
  sqlplus /nolog <<!
WHENEVER SQLERROR EXIT 1
connect $U/"$DB_PASSWORD"@$SVC
@$GRABDISH_HOME/DATABASE2-dotnet/dequeueenqueue.sql
!
  state_set_done DOT_NET_DATABASE2_DB_PROC
done


# DB Setup Done
state_set_done DB_SETUP