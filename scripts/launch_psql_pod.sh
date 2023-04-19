#!/bin/bash

#static vars
AWS_REGION=us-west-1
CLIENT_IMAGE=postgres:10.1-alpine
DB_NAME="automation_calculator_app"
DB_RESOURCE_ADDRESS="module.main_rails_app.aws_db_instance.automation_calculator_app"
DB_USER="automation_calculator_devops"
TARGET_FOLDER="../terraform/env/${ENVIRONMENT}/aws/${AWS_REGION}/cluster-addons-layer"

#computed vars
RDS_ENDPOINT="$(terraform -chdir=${TARGET_FOLDER} state show ${DB_RESOURCE_ADDRESS} | grep endpoint | awk '{print $3}')"
#strip quotes from RDS_ENDPOINT
RDS_ENDPOINT="${RDS_ENDPOINT%\"}"
RDS_ENDPOINT="${RDS_ENDPOINT#\"}"

#exit if environment var is not set
if [ -z "${ENVIRONMENT}" ]; then
  echo "ENVIRONMENT variable is not set. Exiting."
  exit 1
fi

#exit if db pass var is not set
if [ -z "${DB_PASS}" ]; then
  echo "DB_PASS variable is not set. Exiting."
  exit 1
fi

echo "Target DB Host is: ${RDS_ENDPOINT}"

#run pod for postgres client
kubectl run --image=${CLIENT_IMAGE} --rm --tty -i --restart='Never' temp-postgres-client -- psql postgresql://${DB_USER}:${DB_PASS}@${RDS_ENDPOINT}/${DB_NAME}
