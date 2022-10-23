#!/bin/bash

# Reference: https://stackoverflow.com/questions/20337749/exporting-dns-zonefile-from-amazon-route-53

# Prerequisite
# brew install jq


if [ -z "$FROM_AWS_PROFILE" ]
  then
    echo ERROR: Please pass 'FROM_AWS_PROFILE'
    exit 1
fi


if [ -z "$TO_AWS_PROFILE" ]
  then
    echo ERROR: Please pass 'TO_AWS_PROFILE'
    exit 1
fi


ZONE_NAME=$1
if [ -z "$ZONE_NAME" ]
  then
    echo ERROR: Please pass domain need to be copied
    exit 1
fi


FILE_NAME=$2
if [ -z "$FILE_NAME" ]
  then
    echo
    echo WARNING: No second argument fileName is passed to download the record set
    echo
fi


FROM_HOSTED_ZONE_ID=$(
    AWS_PROFILE=$FROM_AWS_PROFILE \
    aws route53 list-hosted-zones --output json \
    | jq -r ".HostedZones[]
    | select(.Name == \"$ZONE_NAME.\")
    | .Id" \
    | cut -d'/' -f3
)


TO_HOSTED_ZONE_ID=$(
    AWS_PROFILE=$TO_AWS_PROFILE \
    aws route53 list-hosted-zones --output json \
    | jq -r ".HostedZones[]
    | select(.Name == \"$ZONE_NAME.\")
    | .Id" \
    | cut -d'/' -f3
)


# Get all record set except SOA and NS for the main domain
HOSTED_ZONE_RECORD_SET=$(
    AWS_PROFILE=$FROM_AWS_PROFILE \
    aws route53 list-resource-record-sets \
    --hosted-zone-id $FROM_HOSTED_ZONE_ID \
    --output json \
    | jq -jr '.ResourceRecordSets' \
    | jq -c --arg HOSTED_ZONE_NAME "$ZONE_NAME." 'map(
        select(
            .Type != "SOA"
            and (
                .Type != "NS"
                or
                .Name != $HOSTED_ZONE_NAME
            )
        )
    )' \
    | jq '{ResourceRecordSets: .}'
)


if [ -z "$FILE_NAME" ]
  then
    echo "Downloadeded Record set from existing Hosted zone:"
    echo
    echo $HOSTED_ZONE_RECORD_SET | jq
    echo
  else
    echo $HOSTED_ZONE_RECORD_SET | jq > $FILE_NAME
fi


UPSERT_RECORD_SET=$(
    echo $HOSTED_ZONE_RECORD_SET \
    | jq -jr '.ResourceRecordSets' \
    | jq .[] \
    | jq '{Action: "UPSERT", ResourceRecordSet: .}' \
    | jq -s . \
    | jq '{
        Comment: "Update Record set to transfer domain from one AWS account to another", 
        Changes: .
    }'
)


CHANGE_INFO=$(
    AWS_PROFILE=$TO_AWS_PROFILE \
    aws route53 change-resource-record-sets \
    --hosted-zone-id $TO_HOSTED_ZONE_ID \
    --change-batch "$UPSERT_RECORD_SET"
)


CHANGE_ID_STRING=$(
    echo $CHANGE_INFO \
    | jq -jr '.ChangeInfo.Id'
)

CHANGE_ID=${CHANGE_ID_STRING:8}

CHANGE_STATUS=$(
    echo $CHANGE_INFO \
    | jq -jr '.ChangeInfo.Status'
)


until [[ "$CHANGE_STATUS" == "INSYNC" ]]; do
    echo "ChangeId: $CHANGE_ID ChangeStatus: $CHANGE_STATUS"
    CHANGE_STATUS=$(
        AWS_PROFILE=$TO_AWS_PROFILE \
        aws route53 get-change --id "$CHANGE_ID" \
        | jq -jr '.ChangeInfo.Status'
    )
    sleep .2 # sleep 2 seconds
done


echo "Transferred Succesfully, Change Status: $CHANGE_STATUS"
